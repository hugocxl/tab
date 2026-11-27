import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class PrivacySettingsTests: XCTestCase {
    private var root: URL!
    private var host: PreviewSettingsHost!
    private var page: SettingsModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        host = PreviewSettingsHost()
        host.privacy = [.camera: .allowed, .microphone: .denied, .calendars: .limited, .photos: .restricted]
        let store = SettingsStore(dirs: TabDirs(root: root), configFile: root.appendingPathComponent("user-settings.json"), host: host, theme: AppTheme(catalog: ThemeCatalog(entries: []), systemIsDark: true))
        page = SettingsModel(store: store)
        page.select(.privacy)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func row(_ permission: PrivacyPermission) throws -> SettingRow {
        try XCTUnwrap(page.lastBuild?.rows.first { $0.id == permission.settingId })
    }

    private func titles(_ control: SettingControl?) -> [String] {
        (control?.leaves ?? []).compactMap {
            switch $0 {
            case .status(let text, _): text
            case .button(let spec): spec.title
            default: nil
            }
        }
    }

    /// Each answer shows a pill, and only answers macOS won't ask again
    /// for offer System Settings.
    func testEachAnswerShowsItsStateAndTheWayToChangeIt() throws {
        XCTAssertEqual(page.lastBuild?.unknownIds, [])
        XCTAssertEqual(titles(try row(.camera).control), ["Allowed"])
        XCTAssertEqual(titles(try row(.microphone).control), ["Denied", "Open System Settings"])
        XCTAssertEqual(titles(try row(.calendars).control), ["Limited", "Open System Settings"])
        XCTAssertEqual(titles(try row(.photos).control), ["Restricted"])
        XCTAssertEqual(titles(try row(.contacts).control), ["Grant Access"])
        XCTAssertNotNil(try row(.microphone).description)
        XCTAssertEqual(titles(page.lastBuild?.rows.first { $0.id == "privacy-files" }?.control), ["Not allowed", "Open System Settings"])
    }

    /// Grant Access waits for one answer, ignores clicks meanwhile, then
    /// shows what macOS answered.
    func testGrantAccessShowsTheAnswer() async throws {
        host.privacyAnswer = .denied
        guard case .button(let grant)? = try row(.contacts).control else { return XCTFail("no Grant Access button") }
        grant.action()
        XCTAssertTrue(page.privacyRequests.contains(.contacts))
        guard case .button(let waiting)? = try row(.contacts).control else { return XCTFail("no waiting button") }
        XCTAssertFalse(waiting.enabled)
        waiting.action()
        for _ in 0..<50 where page.privacyRequests.contains(.contacts) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(page.privacyRequests.isEmpty)
        XCTAssertEqual(titles(try row(.contacts).control), ["Denied", "Open System Settings"])
    }
}
