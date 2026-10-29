import AppKit
import XCTest
@testable import TabApp

final class ProjectIconsTests: XCTestCase {
    private func entry(_ path: String, directory: Bool, ignored: Bool = false) -> ProjectIconEntry {
        ProjectIconEntry(name: String(path.split(separator: "/").last ?? ""), path: path, isDirectory: directory, isIgnored: ignored)
    }

    func testFindsAppIconsNestedInAMonorepoAndSkipsIgnoredFolders() async {
        let found = await ProjectIconFinder.candidates { directory -> [ProjectIconEntry] in
            switch directory {
            case "": return [entry("apps", directory: true), entry("node_modules", directory: true, ignored: true),
                             entry("screenshot.png", directory: false)]
            case "apps": return [entry("apps/desktop", directory: true)]
            case "apps/desktop": return [entry("apps/desktop/src-tauri", directory: true)]
            case "apps/desktop/src-tauri": return [entry("apps/desktop/src-tauri/icons", directory: true)]
            case "apps/desktop/src-tauri/icons":
                return [entry("apps/desktop/src-tauri/icons/AppIconBeta.png", directory: false),
                        entry("apps/desktop/src-tauri/icons/AppIcon.png", directory: false)]
            case "node_modules":
                XCTFail("searched an ignored folder")
                return []
            default: return []
            }
        }
        XCTAssertEqual(found, ["apps/desktop/src-tauri/icons/AppIcon.png", "apps/desktop/src-tauri/icons/AppIconBeta.png"])
    }

    func testIcnsFilesDecodeAndJunkDoesNot() throws {
        let png = try pngData(side: 128)
        var icns = Array("icns".utf8) + bigEndian(UInt32(8 + 8 + png.count))
        icns += Array("ic07".utf8) + bigEndian(UInt32(8 + png.count)) + Array(png)
        XCTAssertNotNil(ProjectIconFinder.decode(Data(icns)))
        XCTAssertNil(ProjectIconFinder.decode(Data("icns\0\0\0\u{10}junk".utf8)))
    }

    func testLocalDiscoveryPrefersTheRootIconAndSkipsGitIgnoredFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for folder in ["generated", "assets", "src"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try git(["init", "-q"], in: root)
        try Data("generated/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try pngData(side: 32).write(to: root.appendingPathComponent("generated/icon.png"))
        try pngData(side: 64).write(to: root.appendingPathComponent("assets/logo-dark.png"))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("src/main.swift"))

        let lister = LocalProjectLister(root: root)
        XCTAssertTrue(lister.list("").contains { $0.path == "generated" && $0.isIgnored })
        let found = await ProjectIconFinder.candidates(list: { lister.list($0) })
        XCTAssertEqual(found, ["assets/logo-dark.png"])

        try pngData(side: 48).write(to: root.appendingPathComponent("logo.png"))
        let ranked = await ProjectIconFinder.candidates(list: { lister.list($0) })
        XCTAssertEqual(ranked.first, "logo.png")
        let image = await ProjectIconFinder.findLocal(root: root)
        XCTAssertEqual(image?.representations.first?.pixelsWide, 48)
    }

    func testArtworkLocationsAndFormatsInARealGitRepository() async throws {
        let root = URL(fileURLWithPath: "/tmp/tab-project-icons-test").appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try git(["init", "-q"], in: root)
        try Data("ignored.ico\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let png = try pngData(side: 64)
        var icns = Data("icns".utf8) + Data(bigEndian(UInt32(16 + png.count)))
        icns += Data("ic07".utf8) + Data(bigEndian(UInt32(8 + png.count))) + png
        var ico = Data([0, 0, 1, 0, 1, 0, 64, 64, 0, 0, 1, 0, 32, 0])
        let size = UInt32(png.count).littleEndian
        ico += withUnsafeBytes(of: size) { Data($0) }
        ico += Data([22, 0, 0, 0]) + png
        try ico.write(to: root.appendingPathComponent("ignored.ico"))
        for directory in ["", "assets", "resources", "public", "packaging"] {
            let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, data) in [("Product.icns", icns), ("favicon.ico", ico), ("icon.png", png), ("logo.png", png)] {
                let file = folder.appendingPathComponent(name)
                try data.write(to: file)
                let relative = directory.isEmpty ? name : "\(directory)/\(name)"
                let lister = LocalProjectLister(root: root)
                let candidates = await ProjectIconFinder.candidates(list: { lister.list($0) })
                XCTAssertEqual(candidates, [relative])
                let image = await ProjectIconFinder.findLocal(root: root)
                XCTAssertNotNil(image, relative)
                try fm.removeItem(at: file)
            }
        }
    }

    func testPNGsMustSayTheyAreIconsAndVariantsRankLast() {
        XCTAssertNil(ProjectIconFinder.rank("screenshot.png", depth: 0))
        XCTAssertNotNil(ProjectIconFinder.rank("screenshot.ico", depth: 0))
        let plain = ProjectIconFinder.rank("app-icon-big.png", depth: 2)
        let dark = ProjectIconFinder.rank("icon-dark.png", depth: 0)
        let named = ProjectIconFinder.rank("logo.png", depth: 3)
        XCTAssertNotNil(plain)
        XCTAssertGreaterThan(named!, plain!)
        XCTAssertLessThan(dark!, plain!)
    }

    @MainActor
    func testCacheLooksUpOncePerProjectUntilInvalidated() async throws {
        let counter = Counter()
        let image = try XCTUnwrap(NSImage(data: pngData(side: 64)))
        let cache = ProjectIconCache(lookup: { _ in
            counter.increment()
            return image
        })
        let arrived = expectation(description: "icon arrived")
        cache.onChange = { _ in arrived.fulfill() }
        XCTAssertNil(cache.icon(for: "/p"))
        await fulfillment(of: [arrived], timeout: 5)
        let icon = try XCTUnwrap(cache.icon(for: "/p", points: 16))
        XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(cache.icon(for: "/p", points: 32)?.size, NSSize(width: 32, height: 32))
        XCTAssertEqual(counter.value, 1)

        let again = expectation(description: "looked up again")
        cache.onChange = { _ in again.fulfill() }
        cache.invalidate("/p")
        XCTAssertNil(cache.icon(for: "/p"))
        await fulfillment(of: [again], timeout: 5)
        XCTAssertEqual(counter.value, 2)
        cache.retain([])
        XCTAssertFalse(cache.isLoaded("/p"))
    }

    private func pngData(side: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", folder.path] + arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
