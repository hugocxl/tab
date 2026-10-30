import CommonCrypto
import SQLite3
import TabCore
import WebKit
import XCTest
@testable import TabApp

final class BrowserImportFixtureTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/tmp/tab-browser-test").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func database(_ name: String, _ sql: String) throws -> URL {
        let file = folder.appendingPathComponent(name)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        XCTAssertEqual(code, SQLITE_OK, database.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
        return file
    }

    func testSafariHistoryAndNestedBinaryPlistBookmarks() throws {
        let file = try database("History.db", """
        CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);
        CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
        INSERT INTO history_items VALUES (1, 'https://safari.example/', 99), (2, 'https://unvisited.example/', 0);
        INSERT INTO history_visits VALUES (1, 1, 700000000, 'Old title'), (2, 1, 700000001.5, 'Newest title');
        """)
        let history = try BrowserImport.safariHistory(file)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[1].title, "Newest title")
        XCTAssertEqual(history[1].lastVisit.timeIntervalSince1970, 1_678_307_201.5)
        let bookmarks: [String: Any] = ["Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://saved.example/", "URIDictionary": ["title": "Saved"]],
            ]],
        ]]
        let plist = folder.appendingPathComponent("Bookmarks.plist")
        try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .binary, options: 0).write(to: plist)
        let source = ExternalBrowserProfile(kind: .safari, browser: "Safari", name: "", folder: folder)
        let imported = try BrowserImport.readHistory(source)
        XCTAssertEqual(imported.visits, history)
        XCTAssertEqual(imported.bookmarks.first?.url, "https://saved.example/")
        XCTAssertEqual(imported.bookmarks.first?.title, "Saved")
        XCTAssertEqual(imported.bookmarks.first?.bookmarked, true)
    }

    func testChromiumHistoryBookmarksAndEncryptedCookieDatabase() throws {
        let history = try database("History", """
        CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER);
        CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);
        INSERT INTO urls VALUES (1, 'https://chrome.example/', 'Chrome', 20, 13344473601000000);
        INSERT INTO visits VALUES (1, 1, 13344473600000000), (2, 1, 13344473601000000);
        """)
        let entries = try BrowserImport.chromiumHistory(history)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].lastVisit.timeIntervalSince1970, 1_700_000_001)
        let bookmarks = #"{"roots":{"bookmark_bar":{"type":"folder","children":[{"type":"folder","children":[{"type":"url","name":"Nested","url":"https://nested.example/"}]}]},"other":{"type":"folder","children":[]}}}"#
        try bookmarks.write(to: folder.appendingPathComponent("Bookmarks"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try BrowserImport.chromiumBookmarks(folder.appendingPathComponent("Bookmarks")).first?.title, "Nested")
        let key = try BrowserImport.chromiumKey(password: Data("fixture-password".utf8))
        let domain = ".chrome.example"
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let bytes = Data(domain.utf8)
        _ = bytes.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(bytes.count), &digest) }
        let encrypted = Data("v10".utf8) + (try BrowserImport.aes128(operation: CCOperation(kCCEncrypt), Data(digest) + Data("secret".utf8), key: key))
        let v11 = Data("v11".utf8) + (try BrowserImport.aes128(operation: CCOperation(kCCEncrypt), Data("0123456789012345678901234567890123456789".utf8), key: key))
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        let cookies = try database("Cookies", """
        CREATE TABLE meta (key TEXT, value TEXT);
        INSERT INTO meta VALUES ('version', '24');
        CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER);
        INSERT INTO cookies VALUES ('\(domain)', 'sid', 'stale', X'\(hex(encrypted))', '/app', 13544473600000000, 1, 1);
        INSERT INTO cookies VALUES ('\(domain)', 'long', '', X'\(hex(v11))', '/', 0, 0, 0);
        INSERT INTO cookies VALUES ('plain.example', 'plain', 'value', X'', '/', 0, 0, 0);
        INSERT INTO cookies VALUES ('raw.example', 'raw', '', X'726177', '/', 0, 0, 0);
        INSERT INTO cookies VALUES ('bad.example', 'broken', '', X'76313000', '/', 0, 0, 0);
        """)
        let imported = try BrowserImport.chromiumCookies(cookies, key: key)
        XCTAssertEqual(imported.count, 4)
        XCTAssertEqual(imported[0].value, "secret")
        XCTAssertEqual(imported[0].expires?.timeIntervalSince1970, 1_900_000_000)
        XCTAssertTrue(imported[0].secure && imported[0].httpOnly)
        XCTAssertEqual(imported[1].value, "0123456789012345678901234567890123456789")
        XCTAssertEqual(imported[2].value, "value")
        XCTAssertEqual(imported[3].value, "raw")
        XCTAssertNil(imported[1].expires)
    }

    func testFirefoxPlacesBookmarksAndCookies() throws {
        let places = try database("places.sqlite", """
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_date INTEGER);
        CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, dateAdded INTEGER, guid TEXT);
        INSERT INTO moz_places VALUES (1, 'https://firefox.example/', 'Firefox', 50, 1700000001000000),
            (2, 'https://saved.example/', NULL, 0, NULL), (3, 'place:sort=8', 'Query', 0, NULL);
        INSERT INTO moz_historyvisits VALUES (1, 1, 1700000000000000), (2, 1, 1700000001000000);
        INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 0, 'root________'),
            (2, 2, NULL, 1, 0, 'toolbar', 0, 'toolbar_____'), (3, 2, NULL, 1, 1, 'tags', 0, 'tags________'),
            (4, 2, NULL, 2, 0, 'Nested', 0, 'folder______'), (5, 1, 2, 4, 0, 'Saved', 0, 'saved_______'),
            (6, 1, 1, 3, 0, 'Tag only', 0, 'tag_________'), (7, 1, 3, 2, 1, 'Query', 0, 'query_______');
        """)
        let history = try BrowserImport.firefoxHistory(places)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[1].lastVisit.timeIntervalSince1970, 1_700_000_001)
        let bookmarks = try BrowserImport.firefoxBookmarks(places)
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks[0].url, "https://saved.example/")
        let cookies = try database("cookies.sqlite", """
        CREATE TABLE moz_cookies (id INTEGER PRIMARY KEY, host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER);
        INSERT INTO moz_cookies VALUES (1, '.firefox.example', 'sid', 'secret', '/app', 1900000000, 1, 1),
            (2, 'firefox.example', 'temporary', 'value', '/', 0, 0, 0);
        """)
        let imported = try BrowserImport.firefoxCookies(cookies)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[0], ImportedCookie(name: "sid", value: "secret", domain: ".firefox.example", path: "/app", secure: true, httpOnly: true, expires: Date(timeIntervalSince1970: 1_900_000_000)))
        XCTAssertNil(imported[1].expires)
    }

    func testDiscoveryIncludesBookmarkOnlyChromiumAndUnlistedFirefoxProfiles() throws {
        let chrome = folder.appendingPathComponent("Custom")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: chrome.appendingPathComponent("Bookmarks"))
        try Data(#"{"profile":{"info_cache":{"Custom":{"name":"Work"}}}}"#.utf8).write(to: folder.appendingPathComponent("Local State"))
        XCTAssertEqual(BrowserImport.chromiumProfiles(folder).map(\.1), ["Work"])
        let firefox = folder.appendingPathComponent("Profiles/unlisted")
        try FileManager.default.createDirectory(at: firefox, withIntermediateDirectories: true)
        try Data().write(to: firefox.appendingPathComponent("places.sqlite"))
        XCTAssertEqual(BrowserImport.firefoxProfiles(folder).map(\.1), ["unlisted"])
        let ini = "[Install123]\nDefault=ignored\n[Profile0]\nName=Named\nIsRelative=1\nPath=Profiles/unlisted\n"
        try ini.write(to: folder.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(BrowserImport.firefoxProfiles(folder).map(\.1), ["Named"])
    }

    func testDamagedBookmarksAreReportedAndMissingFilesAreEmpty() throws {
        let file = folder.appendingPathComponent("Bookmarks")
        XCTAssertTrue(try BrowserImport.chromiumBookmarks(file).isEmpty)
        XCTAssertTrue(try BrowserImport.safariBookmarks(file).isEmpty)
        try Data("damaged".utf8).write(to: file)
        XCTAssertThrowsError(try BrowserImport.chromiumBookmarks(file))
        XCTAssertThrowsError(try BrowserImport.safariBookmarks(file))
    }

    func testSQLiteSnapshotReadsUncheckpointedWALWithoutChangingSource() throws {
        let file = folder.appendingPathComponent("History")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE sample (value TEXT); INSERT INTO sample VALUES ('pending');", nil, nil, nil), SQLITE_OK)
        let original = try Data(contentsOf: file)
        let reader = try SQLiteReader(copying: file)
        XCTAssertEqual(try reader.rows("SELECT value FROM sample") { $0.text(0) }, ["pending"])
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertThrowsError(try reader.rows("SELECT value FROM nonexistent") { $0.text(0) })
    }
}

@MainActor
final class BrowserSecurityTests: XCTestCase {
    func testMalformedProfileIDsAndSymlinksCannotReadOrWriteOutsideProfile() async throws {
        let folder = URL(fileURLWithPath: "/tmp/tab-browser-test").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("browser")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = UUID().uuidString.lowercased()
        let saved = [BrowserProfile(id: "00000000-0000-0000-0000-000000000000", name: "Invalid store"), BrowserProfile(id: "../outside", name: "Escape"), BrowserProfile(id: valid, name: "Valid"), BrowserProfile(id: valid.uppercased(), name: "Duplicate")]
        try JSONEncoder().encode(saved).write(to: root.appendingPathComponent("profiles.json"))
        let profiles = BrowserProfiles(root: root)
        XCTAssertEqual(profiles.profiles.map(\.name), ["Default", "Valid"])
        XCTAssertEqual(profiles.folder(for: BrowserProfile(id: "../outside", name: "Escape")), root.appendingPathComponent("default", isDirectory: true))
        XCTAssertThrowsError(try profiles.resolve("../outside"))
        let outside = folder.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("browser-history.json")
        let original = Data(#"[{"url":"https://secret.example","visitCount":1,"lastVisit":1000}]"#.utf8)
        try original.write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(valid), withDestinationURL: outside)
        let history = profiles.history(for: try profiles.resolve(valid))
        XCTAssertTrue(history.entries.isEmpty)
        history.recordVisit(url: "https://other.example", title: nil)
        history.saveNow()
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testCookieFiltersMatchCodeshHostPathAndSecureRules() throws {
        let secure = try XCTUnwrap(ImportedCookie(name: "sid", value: "x", domain: ".example.test", path: "/app", secure: true).httpCookie)
        XCTAssertTrue(BrowserAutomation.cookie(secure, matches: "www.example.test", path: "/app/page"))
        XCTAssertFalse(BrowserAutomation.cookie(secure, matches: "www.example.test", path: "/apple"))
        XCTAssertFalse(BrowserAutomation.cookie(secure, matches: "example.test", path: "/app", scheme: "http"))
        XCTAssertFalse(BrowserAutomation.cookie(secure, matches: "evilexample.test", path: "/app"))
        let hostOnly = try XCTUnwrap(ImportedCookie(name: "host", value: "x", domain: "example.test").httpCookie)
        XCTAssertTrue(BrowserAutomation.cookie(hostOnly, matches: "EXAMPLE.TEST.", path: "/"))
        XCTAssertFalse(BrowserAutomation.cookie(hostOnly, matches: "sub.example.test", path: "/"))
    }

    func testExplicitDefaultProfileClearDoesNotClearChosenDefaultHistory() async throws {
        let root = URL(fileURLWithPath: "/tmp/tab-browser-test").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = BrowserProfiles(root: root, storeFactory: { _ in .nonPersistent() })
        let work = try profiles.add(named: "Work")
        profiles.defaultProfileId = work.id
        profiles.history(for: work).recordVisit(url: "https://work.example/", title: nil)
        profiles.history(for: profiles.profiles[0]).recordVisit(url: "https://default.example/", title: nil)
        try await profiles.clearData("")
        XCTAssertTrue(profiles.history(for: profiles.profiles[0]).entries.isEmpty)
        XCTAssertEqual(profiles.history(for: work).entries.count, 1)
        profiles.defaultProfileId = ""
        try await profiles.delete(work.id)
    }
}
