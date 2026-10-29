import Foundation
import XCTest
@testable import TabApp

final class CLIInstallTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testInstallsRepairsManagedLinksAndRefusesUnrelatedPaths() throws {
        let fm = FileManager.default
        let target = root.appendingPathComponent("App With Spaces/tab")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("executable".utf8).write(to: target)
        let home = root.appendingPathComponent("home")
        let destination = home.appendingPathComponent(".local/bin/tab")

        try CommandLineInstaller.installLink(target: target, destination: destination)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.path), target.path)
        try CommandLineInstaller.installLink(target: target, destination: destination)

        let moved = root.appendingPathComponent("moved-tab")
        try fm.moveItem(at: target, to: moved)
        try CommandLineInstaller.installLink(target: moved, destination: destination)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.path), moved.path)

        try fm.removeItem(at: destination)
        try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: "/usr/bin/false")
        XCTAssertThrowsError(try CommandLineInstaller.installLink(target: moved, destination: destination))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.path), "/usr/bin/false")

        try fm.removeItem(at: destination)
        try Data("unrelated".utf8).write(to: destination)
        XCTAssertThrowsError(try CommandLineInstaller.installLink(target: moved, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("unrelated".utf8))

        let leftovers = try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".tab-link-") })
    }

    func testOnlyAnInstalledBundleIsLinked() throws {
        let installed = URL(fileURLWithPath: "/Applications/Tab.app/Contents/MacOS/Tab")
        XCTAssertEqual(try CommandLineInstaller.installedTool(executable: installed).path, "/Applications/Tab.app/Contents/MacOS/tab")
        for running in [
            "/Volumes/Tab/Tab.app/Contents/MacOS/Tab",
            "/private/var/folders/x/AppTranslocation/y/d/Tab.app/Contents/MacOS/Tab",
            "/Users/me/Downloads/AppTranslocation/Tab.app/Contents/MacOS/Tab",
            "/Applications/previous.app/Contents/MacOS/Tab",
            "/usr/local/bin/Tab",
            "/Applications/Tab.app/Contents/MacOS/tabd",
        ] {
            XCTAssertThrowsError(try CommandLineInstaller.installedTool(executable: URL(fileURLWithPath: running)), running)
        }
    }

    func testResultExplainsThePathWhenItIsMissing() {
        let link = URL(fileURLWithPath: "/Users/me/.local/bin/tab")
        let onPath = CommandLineInstaller.message(for: .success(link), path: "/usr/bin:/Users/me/.local/bin")
        XCTAssertEqual(onPath.0, "Command Line Tool Installed")
        XCTAssertTrue(onPath.1.contains("tab --help"))
        let offPath = CommandLineInstaller.message(for: .success(link), path: "/usr/bin")
        XCTAssertTrue(offPath.1.contains("export PATH=\"$HOME/.local/bin:$PATH\""))
        let failed = CommandLineInstaller.message(for: .failure(.init("nope")), path: nil)
        XCTAssertEqual(failed.0, "Could Not Install Command Line Tool")
    }
}
