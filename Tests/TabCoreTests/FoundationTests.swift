import XCTest
@testable import TabCore

final class FuzzyTests: XCTestCase {
    func testBasenameAndConsecutiveMatchesOutrankScatteredOnes() {
        let files = ["src/main.rs", "src/map_index.rs", "main/resources/icon.svg", "src/domain.rs", "README.md"]
        let ranked = Fuzzy.rank(files, key: { $0 }, query: "mai", limit: 100)
        XCTAssertEqual(ranked.map(\.item), ["src/main.rs", "src/map_index.rs", "src/domain.rs", "main/resources/icon.svg"])
        XCTAssertEqual(Fuzzy.rank(files, key: { $0 }, query: "MAIN", limit: 100).first?.item, "src/main.rs")
        XCTAssertTrue(Fuzzy.rank(files, key: { $0 }, query: "xyz", limit: 100).isEmpty)
    }

    func testRangesAreUTF16OffsetsOfWholeCharacters() {
        XCTAssertEqual(Fuzzy.match("src/Éclair.rs", Fuzzy.normalize("ÉC"))?.ranges, [4..<5, 5..<6])
        XCTAssertEqual(Fuzzy.match("a😀b", Fuzzy.normalize("b"))?.ranges, [3..<4])
    }

    func testEmptyQueryKeepsShortestKeysFirstAndLimitKeepsTheBest() {
        let ranked = Fuzzy.rank(["beta", "alpha", "be", "gamma-ray"], key: { $0 }, query: "", limit: 3)
        XCTAssertEqual(ranked.map(\.item), ["be", "beta", "alpha"])
        XCTAssertTrue(ranked.allSatisfy { $0.ranges.isEmpty })
        let many = (0..<1000).map { String(format: "src/file_%04d.rs", $0) }
        let limited = Fuzzy.rank(many, key: { $0 }, query: "file", limit: 100)
        XCTAssertEqual(limited.count, 100)
        XCTAssertEqual(limited.first?.item, many[0])
        XCTAssertEqual(limited.last?.item, many[99])
        XCTAssertTrue(Fuzzy.rank(many, key: { $0 }, query: "file", limit: 0).isEmpty)
    }
}

final class FoundationTests: XCTestCase {
    func testReleasesReplaceOnlyOlderReleasesOfTheirChannel() {
        XCTAssertTrue(ReleaseVersion.isNewer("2.0.0-beta.10", than: "2.0.0-beta.9"))
        XCTAssertTrue(ReleaseVersion.isNewer("2.1.0-beta.10", than: "2.0.0-beta.9"))
        XCTAssertFalse(ReleaseVersion.isNewer("2.0.0-beta.9", than: "2.0.0-beta.9"))
        XCTAssertTrue(ReleaseVersion.isNewer("2.0.10", than: "2.0.9"))
        XCTAssertTrue(ReleaseVersion.isNewer("3.0.0", than: "2.9.9"))
        XCTAssertFalse(ReleaseVersion.isNewer("2.0.0", than: "2.0.1"))
        XCTAssertFalse(ReleaseVersion.isNewer("2.0.1", than: "2.0.0-beta.9"))
        XCTAssertFalse(ReleaseVersion.isNewer("2.0.0-beta.10", than: "2.0.0"))
        XCTAssertFalse(ReleaseVersion.isNewer("2.0.0-beta.10", than: "2.0.0-beta-0"))
        XCTAssertNil(ReleaseVersion("2.0.0-beta-1110"))
        XCTAssertNil(ReleaseVersion("2.0.0-beta.01"))
        XCTAssertNil(ReleaseVersion(Release.sourceVersion))
    }

    func testProfileFoldersSeparateBuildsAndHonorTheOverride() throws {
        XCTAssertEqual(try TabDirs.resolveRoot(override: nil, home: "/Users/dev", name: TabDirs.folderName(debug: false)).path, "/Users/dev/Library/Application Support/Tab")
        XCTAssertEqual(TabDirs.folderName(debug: true), "Tab Dev")
        XCTAssertEqual(try TabDirs.resolveRoot(override: "/tmp/t", home: nil, name: "Tab").path, "/tmp/t")
        XCTAssertThrowsError(try TabDirs.resolveRoot(override: "", home: "/Users/dev", name: "Tab"))
        XCTAssertThrowsError(try TabDirs.resolveRoot(override: nil, home: "", name: "Tab"))
        let directory = try TemporaryDirectory()
        let dirs = try TabDirs.profile(environment: ["TAB_DIR": directory.file("profile").path])
        XCTAssertEqual(dirs.settings.lastPathComponent, "settings.json")
        XCTAssertEqual(dirs.state.lastPathComponent, "state.json")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dirs.root.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o700)
        XCTAssertEqual(TabDirs.configHome(environment: ["XDG_CONFIG_HOME": "/x", "HOME": "/h"]).path, "/x/tab")
        XCTAssertEqual(TabDirs.configHome(environment: ["XDG_CONFIG_HOME": "relative", "HOME": "/h"]).path, "/h/.config/tab")
        XCTAssertEqual(TabDirs.abbreviateHome("/Users/dev/code", home: "/Users/dev"), "~/code")
        XCTAssertEqual(TabDirs.abbreviateHome("/Users/dev", home: "/Users/dev/"), "~")
        XCTAssertNil(TabDirs.abbreviateHome("/Users/devops", home: "/Users/dev"))
        XCTAssertNil(TabDirs.abbreviateHome("/etc", home: "/"))
    }

    func testDroppingTheOwnerReleasesTheLockWhileADuplicateIsOpen() throws {
        let directory = try TemporaryDirectory()
        let path = directory.file("installation.lock")
        var owner: FileLock? = try FileLock.tryLock(path)
        let inherited = dup(try XCTUnwrap(owner).fileDescriptor)
        XCTAssertThrowsError(try FileLock.tryLock(path)) { XCTAssertEqual($0 as? FileLock.Failure, .held) }
        owner = nil
        var next: FileLock? = try FileLock.tryLock(path)
        close(inherited)
        XCTAssertThrowsError(try FileLock.tryLock(path))
        next = nil
        XCTAssertNil(next)
        XCTAssertNoThrow(try FileLock.tryLock(path))
    }

    func testAtomicWritesReplaceWholeFilesPrivately() throws {
        let directory = try TemporaryDirectory()
        let path = directory.file("nested/state.json")
        try AtomicFile.write(Data("one".utf8), to: path)
        let reader = try FileHandle(forReadingFrom: path)
        try AtomicFile.write(Data("two".utf8), to: path)
        XCTAssertEqual(try reader.readToEnd(), Data("one".utf8), "an open reader keeps the old file")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "two")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["state.json"])
    }

    func testCommandLinesSplitLikeAShell() throws {
        XCTAssertEqual(try Executable.commandArguments(#"'/Applications/VM Tool/vm' ssh "dev box" --"#), ["/Applications/VM Tool/vm", "ssh", "dev box", "--"])
        XCTAssertEqual(try Executable.commandArguments(#"echo "a\$b\n" c\ d ''"#), ["echo", "a$b\\n", "c d", ""])
        for invalid in ["vm 'unterminated", "", "   ", "trailing\\", "''", "line\nbreak"] {
            XCTAssertThrowsError(try Executable.commandArguments(invalid), invalid)
        }
        let directory = try TemporaryDirectory()
        let script = try directory.write("tabd", "#!/bin/sh\n")
        XCTAssertFalse(Executable.isExecutableFile(script))
        chmod(script.path, 0o755)
        XCTAssertTrue(Executable.isExecutableFile(script))
        XCTAssertEqual(Executable.sibling("tabd", of: directory.file("tab")), script)
        XCTAssertNil(Executable.sibling("missing", of: directory.file("tab")))
        XCTAssertEqual(try Executable.serverURL(environment: ["TAB_SERVER_BIN": "/opt/tabd"]).path, "/opt/tabd")
        XCTAssertThrowsError(try Executable.serverURL(environment: ["TAB_SERVER_BIN": ""]))
        XCTAssertEqual(Executable.containingBundle(of: URL(fileURLWithPath: "/Applications/Tab.app/Contents/MacOS/tab"))?.path, "/Applications/Tab.app")
        XCTAssertNil(Executable.containingBundle(of: URL(fileURLWithPath: "/usr/local/bin/tab")))
    }

    func testRelativeAgesAndIdentifiers() throws {
        XCTAssertEqual(RelativeTime.ago(seconds: 59), "just now")
        XCTAssertEqual(RelativeTime.ago(seconds: 300), "5m ago")
        XCTAssertEqual(RelativeTime.ago(seconds: 3 * 3600), "3h ago")
        XCTAssertEqual(RelativeTime.ago(seconds: 2 * 86400 + 5), "2d ago")
        let id = try XCTUnwrap(ProjectId("6F9619FF8B86D011B42D00C04FC964FF"))
        XCTAssertEqual(id.description, "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        XCTAssertEqual(Array(try roundTrip([id: TabId()]).keys), [id])
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([id: 1]), as: UTF8.self), #"{"6f9619ff-8b86-d011-b42d-00c04fc964ff":1}"#)
        XCTAssertNil(SessionId("not-a-uuid"))
        XCTAssertTrue(ServerId.local.isLocal)
        XCTAssertEqual(ServerId.local.description, "9eedd633-57b5-4359-b76e-762c6bc2775c")
    }
}
