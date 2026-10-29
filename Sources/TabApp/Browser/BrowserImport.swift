import CommonCrypto
import Foundation
import Security
import SQLite3

/// A cookie read from another browser.
public struct ImportedCookie: Equatable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var secure: Bool
    public var httpOnly: Bool
    /// `nil` for a session cookie.
    public var expires: Date?

    public init(name: String, value: String, domain: String, path: String = "/", secure: Bool = false,
                httpOnly: Bool = false, expires: Date? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.httpOnly = httpOnly
        self.expires = expires
    }

    /// The cookie for a `WKHTTPCookieStore`, or `nil` when it is invalid.
    public var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}

/// History and bookmarks read from another browser.
public struct ImportedHistory: Sendable {
    public var visits: [BrowserHistoryEntry]
    public var bookmarks: [BrowserHistoryEntry]
}

/// Another browser's profile on this Mac.
public struct ExternalBrowserProfile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case safari
        /// A Chromium browser and its Keychain item, such as "Chrome Safe Storage".
        case chromium(browser: String, keychainService: String)
        case firefox
    }

    public var kind: Kind
    /// The browser's name, such as "Chrome".
    public var browser: String
    /// The profile's name, such as "Work"; empty for Safari.
    public var name: String
    public var folder: URL

    /// "Safari", or "Chrome — Work".
    public var displayName: String { name.isEmpty ? browser : "\(browser) — \(name)" }

    public var supportsCookies: Bool {
        switch kind {
        case .safari: return BrowserImport.safariCookiesFile.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
        case .chromium: return BrowserImport.chromiumCookiesFile(folder) != nil
        case .firefox: return FileManager.default.fileExists(atPath: folder.appendingPathComponent("cookies.sqlite").path)
        }
    }
}

/// Reads history, bookmarks and cookies from Safari, Chromium browsers
/// (Chrome, Brave, Edge, Arc, Vivaldi, Chromium) and Firefox. Databases are
/// copied to a temporary file first, since their browser may hold them open.
public enum BrowserImport {
    static let chromiumBrowsers: [(name: String, folder: String, service: String)] = [
        ("Chrome", "Google/Chrome", "Chrome Safe Storage"),
        ("Chromium", "Chromium", "Chromium Safe Storage"),
        ("Brave", "BraveSoftware/Brave-Browser", "Brave Safe Storage"),
        ("Edge", "Microsoft Edge", "Microsoft Edge Safe Storage"),
        ("Arc", "Arc/User Data", "Arc Safe Storage"),
        ("Vivaldi", "Vivaldi", "Vivaldi Safe Storage"),
    ]

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var safariCookiesFile: URL? {
        let candidates = [
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every profile of another browser found on this Mac.
    public static func detect() -> [ExternalBrowserProfile] {
        var found: [ExternalBrowserProfile] = []
        let fileManager = FileManager.default
        let safari = home.appendingPathComponent("Library/Safari")
        if fileManager.fileExists(atPath: safari.appendingPathComponent("History.db").path)
            || fileManager.fileExists(atPath: safari.appendingPathComponent("Bookmarks.plist").path) {
            found.append(ExternalBrowserProfile(kind: .safari, browser: "Safari", name: "", folder: safari))
        }
        let support = home.appendingPathComponent("Library/Application Support")
        for browser in chromiumBrowsers {
            let base = support.appendingPathComponent(browser.folder)
            for (folder, name) in chromiumProfiles(base) {
                found.append(ExternalBrowserProfile(
                    kind: .chromium(browser: browser.name, keychainService: browser.service),
                    browser: browser.name, name: name, folder: folder))
            }
        }
        for (folder, name) in firefoxProfiles(support.appendingPathComponent("Firefox")) {
            found.append(ExternalBrowserProfile(kind: .firefox, browser: "Firefox", name: name, folder: folder))
        }
        return found
    }

    static func chromiumProfiles(_ base: URL) -> [(URL, String)] {
        let fileManager = FileManager.default
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: base.appendingPathComponent("Local State")),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, info) in cache {
                names[folder] = (info as? [String: Any])?["name"] as? String ?? folder
            }
        }
        let folders = ((try? fileManager.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .filter { fileManager.fileExists(atPath: base.appendingPathComponent($0).appendingPathComponent("History").path) }
            .sorted()
        return folders.map { (base.appendingPathComponent($0, isDirectory: true), names[$0] ?? $0) }
    }

    static func firefoxProfiles(_ base: URL) -> [(URL, String)] {
        guard let ini = try? String(contentsOf: base.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
        var result: [(URL, String)] = []
        var name: String?
        var path: String?
        var relative = true
        func flush() {
            defer { name = nil; path = nil; relative = true }
            guard let path else { return }
            let folder = relative ? base.appendingPathComponent(path, isDirectory: true) : URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("places.sqlite").path) else { return }
            result.append((folder, name ?? folder.lastPathComponent))
        }
        for line in ini.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") {
                flush()
                continue
            }
            let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Name": name = parts[1]
            case "Path": path = parts[1]
            case "IsRelative": relative = parts[1] != "0"
            default: break
            }
        }
        flush()
        return result
    }

    // MARK: History and bookmarks

    public static func readHistory(_ source: ExternalBrowserProfile) throws -> ImportedHistory {
        switch source.kind {
        case .safari:
            return ImportedHistory(
                visits: (try? safariHistory(source.folder.appendingPathComponent("History.db"))) ?? [],
                bookmarks: safariBookmarks(source.folder.appendingPathComponent("Bookmarks.plist")))
        case .chromium:
            return ImportedHistory(
                visits: try chromiumHistory(source.folder.appendingPathComponent("History")),
                bookmarks: chromiumBookmarks(source.folder.appendingPathComponent("Bookmarks")))
        case .firefox:
            let places = source.folder.appendingPathComponent("places.sqlite")
            return ImportedHistory(visits: try firefoxHistory(places), bookmarks: (try? firefoxBookmarks(places)) ?? [])
        }
    }

    /// Seconds between 2001-01-01 (Core Data) and the Unix epoch.
    private static let coreDataEpoch: TimeInterval = 978_307_200
    /// Microseconds between 1601-01-01 (WebKit/Chrome) and the Unix epoch.
    private static let chromeEpochMicroseconds: Int64 = 11_644_473_600_000_000

    static func safariHistory(_ file: URL) throws -> [BrowserHistoryEntry] {
        try SQLiteReader(copying: file).rows("""
            SELECT i.url, (SELECT v.title FROM history_visits v WHERE v.history_item = i.id ORDER BY v.visit_time DESC LIMIT 1),
                   i.visit_count, (SELECT MAX(v.visit_time) FROM history_visits v WHERE v.history_item = i.id)
            FROM history_items i
            """) { row in
            guard let url = row.text(0) else { return nil }
            return BrowserHistoryEntry(url: url, title: row.text(1), visitCount: max(row.int(2), 1),
                                       lastVisit: Date(timeIntervalSince1970: row.double(3) + coreDataEpoch))
        }
    }

    static func safariBookmarks(_ file: URL) -> [BrowserHistoryEntry] {
        guard let data = try? Data(contentsOf: file),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        var result: [BrowserHistoryEntry] = []
        func walk(_ node: [String: Any]) {
            if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf", let url = node["URLString"] as? String {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                result.append(BrowserHistoryEntry(url: url, title: title, visitCount: 0, lastVisit: Date(timeIntervalSince1970: 0), bookmarked: true))
            }
            for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(root)
        return result
    }

    static func chromiumHistory(_ file: URL) throws -> [BrowserHistoryEntry] {
        try SQLiteReader(copying: file).rows("SELECT url, title, visit_count, last_visit_time FROM urls") { row in
            guard let url = row.text(0) else { return nil }
            return BrowserHistoryEntry(url: url, title: row.text(1), visitCount: max(row.int(2), 1),
                                       lastVisit: chromeDate(row.int64(3)) ?? Date(timeIntervalSince1970: 0))
        }
    }

    static func chromiumBookmarks(_ file: URL) -> [BrowserHistoryEntry] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any]
        else { return [] }
        var result: [BrowserHistoryEntry] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "url", let url = node["url"] as? String {
                result.append(BrowserHistoryEntry(url: url, title: node["name"] as? String, visitCount: 0,
                                                  lastVisit: Date(timeIntervalSince1970: 0), bookmarked: true))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for case let root as [String: Any] in roots.values { walk(root) }
        return result
    }

    static func firefoxHistory(_ file: URL) throws -> [BrowserHistoryEntry] {
        try SQLiteReader(copying: file).rows("SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE visit_count > 0") { row in
            guard let url = row.text(0) else { return nil }
            return BrowserHistoryEntry(url: url, title: row.text(1), visitCount: max(row.int(2), 1),
                                       lastVisit: Date(timeIntervalSince1970: row.double(3) / 1_000_000))
        }
    }

    static func firefoxBookmarks(_ file: URL) throws -> [BrowserHistoryEntry] {
        try SQLiteReader(copying: file).rows("SELECT p.url, b.title FROM moz_bookmarks b JOIN moz_places p ON p.id = b.fk WHERE b.type = 1") { row in
            guard let url = row.text(0) else { return nil }
            return BrowserHistoryEntry(url: url, title: row.text(1), visitCount: 0, lastVisit: Date(timeIntervalSince1970: 0), bookmarked: true)
        }
    }

    static func chromeDate(_ microseconds: Int64) -> Date? {
        guard microseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(microseconds - chromeEpochMicroseconds) / 1_000_000)
    }

    // MARK: Cookies

    public static func readCookies(_ source: ExternalBrowserProfile) throws -> [ImportedCookie] {
        switch source.kind {
        case .safari:
            guard let file = safariCookiesFile else { throw BrowserScripts.Failure("Safari's cookies were not found") }
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw BrowserScripts.Failure("Tab needs Full Disk Access to read Safari's cookies")
            }
            return try parseBinaryCookies(data)
        case .chromium(_, let service):
            guard let file = chromiumCookiesFile(source.folder) else { throw BrowserScripts.Failure("No cookies were found") }
            let key = try chromiumKey(password: try keychainPassword(service: service))
            return try chromiumCookies(file, key: key)
        case .firefox:
            return try firefoxCookies(source.folder.appendingPathComponent("cookies.sqlite"))
        }
    }

    static func chromiumCookiesFile(_ folder: URL) -> URL? {
        [folder.appendingPathComponent("Network/Cookies"), folder.appendingPathComponent("Cookies")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The Safe Storage password Chromium keeps in the login Keychain. macOS
    /// asks the user to allow it.
    static func keychainPassword(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw BrowserScripts.Failure("Could not read “\(service)” from the Keychain (\(status))")
        }
        return data
    }

    /// The AES-128 key Chromium derives from its Safe Storage password.
    public static func chromiumKey(password: Data) throws -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
            }
        }
        guard status == kCCSuccess else { throw BrowserScripts.Failure("Could not derive the cookie key") }
        return key
    }

    /// Decrypts a `v10` Chromium cookie value. Databases from version 24 on
    /// put a SHA-256 of the host before the value; `hashPrefix` drops it.
    public static func decryptChromiumValue(_ encrypted: Data, key: Data, hashPrefix: Bool) throws -> String {
        guard encrypted.count > 3 else { return "" }
        let prefix = encrypted.prefix(3)
        guard prefix == Data("v10".utf8) else { throw BrowserScripts.Failure("unsupported cookie encryption") }
        let payload = Data(encrypted.dropFirst(3))
        let plain = try aes128(operation: CCOperation(kCCDecrypt), payload, key: key)
        let value = hashPrefix && plain.count >= 32 ? plain.dropFirst(32) : plain[...]
        return String(decoding: value, as: UTF8.self)
    }

    /// AES-128-CBC with PKCS#7 padding and an IV of 16 spaces, as Chromium uses.
    public static func aes128(operation: CCOperation, _ input: Data, key: Data) throws -> Data {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw BrowserScripts.Failure("Could not decrypt a cookie") }
        return output.prefix(written)
    }

    static func chromiumCookies(_ file: URL, key: Data) throws -> [ImportedCookie] {
        let reader = try SQLiteReader(copying: file)
        let version = (try? reader.rows("SELECT value FROM meta WHERE key = 'version'") { Int($0.text(0) ?? "") }.first) ?? 0
        let hashPrefix = version >= 24
        return try reader.rows("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly FROM cookies") { row in
            guard let domain = row.text(0), let name = row.text(1) else { return nil }
            var value = row.text(2) ?? ""
            if value.isEmpty, let encrypted = row.blob(3), !encrypted.isEmpty {
                guard let decrypted = try? decryptChromiumValue(encrypted, key: key, hashPrefix: hashPrefix) else { return nil }
                value = decrypted
            }
            return ImportedCookie(name: name, value: value, domain: domain, path: row.text(4) ?? "/",
                                  secure: row.int(6) != 0, httpOnly: row.int(7) != 0, expires: chromeDate(row.int64(5)))
        }
    }

    static func firefoxCookies(_ file: URL) throws -> [ImportedCookie] {
        try SQLiteReader(copying: file).rows("SELECT host, name, value, path, expiry, isSecure, isHttpOnly FROM moz_cookies") { row in
            guard let domain = row.text(0), let name = row.text(1) else { return nil }
            var expiry = row.double(4)
            if expiry > 100_000_000_000 { expiry /= 1000 }
            return ImportedCookie(name: name, value: row.text(2) ?? "", domain: domain, path: row.text(3) ?? "/",
                                  secure: row.int(5) != 0, httpOnly: row.int(6) != 0,
                                  expires: expiry > 0 ? Date(timeIntervalSince1970: expiry) : nil)
        }
    }

    /// Safari's `Cookies.binarycookies`: big-endian page table, then
    /// little-endian pages of cookie records with Core Data dates.
    public static func parseBinaryCookies(_ data: Data) throws -> [ImportedCookie] {
        let bytes = [UInt8](data)
        let invalid = BrowserScripts.Failure("Safari's cookie file is not readable")
        func be32(_ offset: Int) throws -> Int {
            guard offset + 4 <= bytes.count else { throw invalid }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        func le32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 4 <= bytes.count else { throw invalid }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        func double(_ offset: Int) throws -> Double {
            guard offset >= 0, offset + 8 <= bytes.count else { throw invalid }
            var raw: UInt64 = 0
            for index in 0 ..< 8 { raw |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
            return Double(bitPattern: raw)
        }
        func cString(_ offset: Int) -> String {
            guard offset >= 0, offset < bytes.count else { return "" }
            let end = bytes[offset...].firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[offset ..< end], as: UTF8.self)
        }
        guard bytes.count >= 8, bytes.prefix(4) == [0x63, 0x6F, 0x6F, 0x6B] else { throw invalid }
        let pageCount = try be32(4)
        var sizes: [Int] = []
        for page in 0 ..< pageCount { sizes.append(try be32(8 + page * 4)) }
        var pageStart = 8 + pageCount * 4
        var cookies: [ImportedCookie] = []
        for size in sizes {
            let cookieCount = try le32(pageStart + 4)
            for item in 0 ..< cookieCount {
                let start = pageStart + (try le32(pageStart + 8 + item * 4))
                let flags = try le32(start + 8)
                let domain = cString(start + (try le32(start + 16)))
                let name = cString(start + (try le32(start + 20)))
                let path = cString(start + (try le32(start + 24)))
                let value = cString(start + (try le32(start + 28)))
                let expiry = try double(start + 40)
                cookies.append(ImportedCookie(
                    name: name, value: value, domain: domain, path: path,
                    secure: flags & 1 != 0, httpOnly: flags & 4 != 0,
                    expires: expiry > 0 ? Date(timeIntervalSince1970: expiry + coreDataEpoch) : nil))
            }
            pageStart += size
        }
        return cookies
    }
}

/// A read-only SQLite database opened from a temporary copy.
final class SQLiteReader {
    struct Row {
        let statement: OpaquePointer

        func text(_ column: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: pointer)
        }

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

        func blob(_ column: Int32) -> Data? {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return nil }
            return Data(bytes: pointer, count: count)
        }
    }

    private var database: OpaquePointer?
    private let folder: URL

    init(copying file: URL) throws {
        let fileManager = FileManager.default
        folder = fileManager.temporaryDirectory.appendingPathComponent("tab-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        do {
            try fileManager.copyItem(at: file, to: copy)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: file.path + suffix)
                if fileManager.fileExists(atPath: side.path) {
                    try? fileManager.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
                }
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw BrowserScripts.Failure("Could not read \(file.lastPathComponent): \(error.localizedDescription)")
        }
        guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            try? fileManager.removeItem(at: folder)
            throw BrowserScripts.Failure("Could not open \(file.lastPathComponent)")
        }
    }

    deinit {
        sqlite3_close(database)
        try? FileManager.default.removeItem(at: folder)
    }

    func rows<T>(_ sql: String, _ transform: (Row) -> T?) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_finalize(statement)
            throw BrowserScripts.Failure("Could not read the browser's data: \(message)")
        }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = transform(Row(statement: statement)) { result.append(value) }
        }
        return result
    }
}
