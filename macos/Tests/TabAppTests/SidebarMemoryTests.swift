import AppKit
import XCTest
import TabProtocol
@testable import TabApp

@MainActor
final class SidebarMemoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRemembersGitIconsAndFaviconsAcrossLaunches() throws {
        let file = folder.appendingPathComponent("sidebar-cache.json")
        let repository = ProjectId()
        let plain = ProjectId()
        let png = try XCTUnwrap(SidebarMemory.thumbnail(NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }))
        let memory = SidebarMemory(file: file)
        memory.setGit(repository, GitInfo(summary: GitSummary(branch: "feature", base: "main"), pullRequest: 12))
        memory.setGit(plain, GitInfo(summary: nil))
        memory.setIcon("/code/app", png: png)
        memory.setIcon("/code/none", png: nil)
        memory.setFavicon(png, for: "https://github.com/hugocxl/tab/pulls")
        memory.saveNow()

        let next = SidebarMemory(file: file)
        XCTAssertEqual(next.git(repository), GitInfo(summary: GitSummary(branch: "feature", base: "main"), pullRequest: 12))
        XCTAssertEqual(next.git(plain)?.isRepository, false)
        XCTAssertNil(next.git(ProjectId()))
        XCTAssertEqual(next.iconPNG("/code/app"), png)
        XCTAssertNil(next.iconPNG("/code/none"))
        XCTAssertNotNil(next.favicon(for: "https://GitHub.com/other"))
        XCTAssertNil(next.favicon(for: "http://github.com/"), "another scheme is another site")

        next.retain(projects: [plain])
        next.retain(iconKeys: [])
        XCTAssertNil(next.git(repository))
        XCTAssertNil(next.iconPNG("/code/app"))
    }

    /// The cache only grows: newer builds' keys are ignored, and a damaged
    /// file starts empty rather than failing the launch.
    func testToleratesUnknownKeysAndDamagedFiles() throws {
        let file = folder.appendingPathComponent("sidebar-cache.json")
        let project = ProjectId()
        let json = """
        {"future":1,"git":{"\(project)":{"summary":{"branch":"main","ahead":0,"behind":0,"changed":0,"staged":0,
        "unstaged":0,"untracked":0,"conflicted":0,"later":true}}}}
        """
        try Data(json.utf8).write(to: file)
        XCTAssertEqual(SidebarMemory(file: file).git(project)?.summary?.branch, "main")
        try Data("{not json".utf8).write(to: file)
        XCTAssertNil(SidebarMemory(file: file).git(project))
    }

    func testOrigins() {
        XCTAssertEqual(SidebarMemory.origin("http://localhost:3000/a?b"), "http://localhost:3000")
        XCTAssertEqual(SidebarMemory.origin("https://Example.com"), "https://example.com")
        XCTAssertNil(SidebarMemory.origin("file:///tmp/a.html"))
        XCTAssertNil(SidebarMemory.origin("not a url"))
    }

    func testThumbnailsFitTheirSquare() throws {
        let wide = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(SidebarMemory.thumbnail(wide))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, SidebarMemory.iconPixels)
        XCTAssertEqual(bitmap.pixelsHigh, SidebarMemory.iconPixels)
    }
}
