import Foundation
import TabCore
import TabProtocol
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

    func testFakeBundleInstallsWithOverriddenHomeAndRejectsChangedBuilds() throws {
        let folder = URL(fileURLWithPath: "/tmp/tab-cli-test").appendingPathComponent(UUID().uuidString)
        let macOS = folder.appendingPathComponent("Tab.app/Contents/MacOS")
        let home = folder.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let original { setenv("HOME", original, 1) } else { unsetenv("HOME") }
        }
        let expected = BuildInfo(version: "1.0.0")
        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        for name in ["tab", "tabd"] {
            let tool = macOS.appendingPathComponent(name)
            let script = "#!/bin/sh\nif [ \"$1\" = --build-info ]; then printf '%s' '\(json)'; else printf 'tab fixture'; fi\n"
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let target = macOS.appendingPathComponent("tab")
        let link = try CommandLineInstaller.installBundledTool(target: target, home: URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]!), expected: expected)
        XCTAssertEqual(link.path, home.appendingPathComponent(".local/bin/tab").path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        let process = Process()
        process.executableURL = link
        process.arguments = ["--help"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let answer = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "tab fixture")
        XCTAssertEqual(CommandLineInstaller.message(for: .success(link), path: link.deletingLastPathComponent().path).1,
                       "Installed \(link.path).\n\nRun tab --help in your terminal.")
        XCTAssertThrowsError(try CommandLineInstaller.installBundledTool(target: target, home: home, expected: BuildInfo(version: "2.0.0"))) { error in
            XCTAssertEqual((error as? CommandLineInstaller.InstallError)?.description,
                           "The installed app changed. Reopen it before installing the command line tool.")
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertThrowsError(try CommandLineInstaller.installedTool(executable: macOS.appendingPathComponent("Tab")))
    }

    func testCorruptReceiptAndDirectoryTargetsCannotReplaceACommand() throws {
        let target = root.appendingPathComponent("tool")
        let destination = root.appendingPathComponent("bin/tab")
        try Data("tool".utf8).write(to: target)
        try CommandLineInstaller.installLink(target: target, destination: destination)
        try Data("bad receipt".utf8).write(to: destination.deletingLastPathComponent().appendingPathComponent(".tab-cli-link.json"))
        XCTAssertThrowsError(try CommandLineInstaller.installLink(target: target, destination: destination))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)
        XCTAssertThrowsError(try CommandLineInstaller.installLink(target: root, destination: destination))
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
