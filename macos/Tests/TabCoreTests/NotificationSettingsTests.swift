import XCTest
@testable import TabCore

final class NotificationSettingsTests: XCTestCase {
    func testOlderAndNewerFilesKeepEveryoneElsesChoices() throws {
        let older = try JSONDecoder().decode(Settings.self, from: Data(#"{"browser": {"searchEngine": "bing"}}"#.utf8))
        XCTAssertEqual(older.notifications, NotificationSettings(), "a file from before Notifications gets the defaults")

        let newer = """
        {"notifications": {"position": "middleLeft", "playSounds": false, "future": 1,
                           "done": {"sound": "chime", "dockBadge": false, "vibrate": true}}}
        """
        let notifications = try JSONDecoder().decode(Settings.self, from: Data(newer.utf8)).notifications
        XCTAssertEqual(notifications.position, .bottomRight, "a position from a newer build falls back")
        XCTAssertEqual(notifications.done.sound, .success, "a sound from a newer build falls back")
        XCTAssertFalse(notifications.playSounds)
        XCTAssertFalse(notifications.done.dockBadge)
        XCTAssertTrue(notifications.done.enabled)
    }

    func testSavingNotificationsKeepsTheFilesOtherSections() throws {
        let directory = try TemporaryDirectory()
        let path = try directory.write("settings.json", #"{"browser": {"searchEngine": "bing"}, "future": {"x": 1}}"#)
        var settings = try Settings.load(path)
        settings.notifications.position = .topLeft
        settings.notifications.blocked.playSound = false
        try settings.saveNotifications(to: path)
        let saved = try Settings.load(path)
        XCTAssertEqual(saved.notifications, settings.notifications)
        XCTAssertEqual(saved.browser.searchEngine, .bing)
        XCTAssertTrue(try directory.read("settings.json").contains("future"))
    }

    func testMasterSwitchesAndDisabledStatusesSilenceEveryChannel() {
        var settings = NotificationSettings()
        XCTAssertTrue(settings.notifies(.done))
        XCTAssertEqual(settings.sound(.blocked), .attention)
        XCTAssertFalse(settings.notifies(.working), "working stays quiet by default")
        XCTAssertEqual(settings.channels(.done), "Tabs, Notifications, Dock Badge, Sound")

        settings.playSounds = false
        XCTAssertNil(settings.sound(.done))
        settings.systemNotifications = false
        XCTAssertFalse(settings.notifies(.done))
        XCTAssertEqual(settings.channels(.done), "Tabs, Dock Badge")

        settings.error.enabled = false
        XCTAssertFalse(settings.showsInTabs(.error))
        XCTAssertFalse(settings.badges(.error))
        XCTAssertEqual(settings.channels(.error), "Off")
    }
}
