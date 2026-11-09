import AppKit
import QuartzCore
import XCTest
import TabCore
@testable import TabApp

@MainActor
final class NoticeTests: XCTestCase {
    private func notice(_ message: String) -> Notice {
        Notice(tone: .neutral, icon: .icon(.infoFill), message: message)
    }

    func testStackKeepsNewestFirstUpdatesInPlaceAndDropsTheOldestTimedNotice() {
        let stack = NoticeStack(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        stack.show(notice("Updating"), id: "update")
        let toasts = (1...NoticeStack.capacity).map { stack.show(notice("Toast \($0)"), lifetime: 4) }
        XCTAssertEqual(stack.ids.count, NoticeStack.capacity)
        XCTAssertEqual(stack.ids.first, toasts.last)
        XCTAssertTrue(stack.ids.contains("update"), "a notice without a lifetime outlasts toasts")
        XCTAssertFalse(stack.ids.contains(toasts[0]))

        stack.show(notice("Downloading 40%"), id: "update")
        XCTAssertEqual(stack.ids.count, NoticeStack.capacity, "the same id updates its notice")
        XCTAssertEqual(stack.notice("update")?.message, "Downloading 40%")

        stack.remove("update")
        XCTAssertNil(stack.notice("update"))
    }

    func testIconTransitionsPreserveTemplateTintAndHideProgressRings() throws {
        let view = NoticeIcon(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        view.color = .systemRed
        view.icon = .icon(.infoFill)
        let glyph = try XCTUnwrap(view.subviews.compactMap { $0 as? NSImageView }.first)
        let image = try XCTUnwrap(glyph.image)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size.height, 17)
        XCTAssertEqual(glyph.contentTintColor, .systemRed)
        XCTAssertFalse(glyph.isHidden)

        view.icon = .progress(0.5)
        XCTAssertTrue(glyph.isHidden)
        view.icon = .spinner
        XCTAssertTrue(glyph.isHidden)
        view.icon = .icon(.circleCheckFill)
        view.color = .systemGreen
        XCTAssertFalse(glyph.isHidden)
        XCTAssertEqual(glyph.contentTintColor, .systemGreen)
        XCTAssertFalse(glyph.image === image)
        let rings = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer })
        XCTAssertFalse(rings.isEmpty)
        XCTAssertTrue(rings.allSatisfy(\.isHidden))
        XCTAssertTrue(rings.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
    }

    func testStackTakesClicksOnlyOnItsNotices() throws {
        let window = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let stack = NoticeStack(frame: window.bounds)
        window.addSubview(stack)
        stack.show(notice("Copied"), lifetime: 4)
        stack.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.hitTest(NSPoint(x: 10, y: 590)) === window, "panes under the empty stack still get clicks")
        let shown = try XCTUnwrap(stack.subviews.compactMap { $0 as? NoticeView }.first)
        let center = stack.convert(NSPoint(x: shown.frame.midX, y: shown.frame.midY), to: window)
        let hit = try XCTUnwrap(window.hitTest(center))
        XCTAssertTrue(hit === shown || hit.isDescendant(of: shown))
    }

    func testEverySoundRendersAudibleFiniteSamplesAndAValidWav() {
        var random = SystemRandomNumberGenerator()
        for sound in NotificationSound.allCases {
            let samples = BubbleSounds.render(sound, random: &random)
            XCTAssertFalse(samples.isEmpty, "\(sound)")
            XCTAssertTrue(samples.allSatisfy(\.isFinite), "\(sound)")
            let peak = samples.map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.01, "\(sound) is silent")
            XCTAssertLessThanOrEqual(peak, 1, "\(sound) clips")
            XCTAssertLessThan(Double(samples.count) / BubbleSounds.sampleRate, 1, "\(sound) is a short cue")
            let wav = BubbleSounds.wav(samples)
            XCTAssertEqual(wav.count, 44 + samples.count * 2)
            XCTAssertNotNil(NSSound(data: wav), "\(sound)")
        }
    }

    func testEventsMapToStatuses() {
        XCTAssertEqual(EventKind.attention.status, .blocked)
        XCTAssertEqual(EventKind.completed.status, .done)
        XCTAssertEqual(EventKind.notification.status, .done)
    }
}
