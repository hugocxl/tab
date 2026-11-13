import AppKit
@testable import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentComposerSurfaceTests: XCTestCase {
    func testEmptyComposerCentersAndPlanChipFitsWithoutOverlappingControls() throws {
        for width in [CGFloat(360), 680, 1000] {
            let view = surface(width: width)
            let card = view.composerScroll.superview
            // The greeting above and the composer are centered together.
            XCTAssertEqual(card?.frame.midY ?? 0, view.bounds.midY + 40, accuracy: 1)
            view.plan.isHidden = false
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            if let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
                let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                view.composer.planning = true
                view.theme = AppTheme(systemIsDark: true)
                view.themeDidChange()
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "/empty-plan-\(Int(width)).png"))
                window.close()
            }
            for other in [view.attach, view.modelPicker, view.send, view.stop] {
                XCTAssertFalse(view.plan.frame.intersects(other.frame))
            }
        }
    }

    func testComposerElevationPreservesDarkModeAndBrightensLightMode() {
        for dark in [false, true] {
            let scheme = ColorScheme(background: RGBColor(dark ? 0x102030 : 0xF0E0D0),
                                     foreground: RGBColor(dark ? 0xD0E0F0 : 0x203040))
            let theme = AppTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Fixture", scheme: scheme)]),
                                 darkTheme: "Fixture", lightTheme: "Fixture", systemIsDark: dark)
            if dark { XCTAssertEqual(theme.agentComposer, theme.floating) }
            else { XCTAssertGreaterThan(RGBColor(theme.agentComposer).red, RGBColor(theme.card).red) }
        }
    }

    private func surface(width: CGFloat = 680) -> AgentPaneView {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        surface.model.addItem(withTitle: "A custom model with a very long name")
        surface.effort.addItem(withTitle: "Extra high")
        surface.layoutSubtreeIfNeeded()
        return surface
    }

    func testModelAndEffortShareOneSelectorOnTheControlRow() {
        for width in [CGFloat(360), 560, 680, 1000] {
            let surface = surface(width: width)
            surface.plan.isHidden = false
            surface.needsLayout = true
            surface.layoutSubtreeIfNeeded()
            let picker = surface.modelPicker
            XCTAssertFalse(picker.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(surface.model.isHidden && surface.effort.isHidden, "The pop-ups only hold the menus")
            XCTAssertTrue(picker.labelText.contains("A custom model") && picker.labelText.contains("Extra high"))
            XCTAssertGreaterThanOrEqual(picker.frame.width, 70, "at \(width)pt")
            XCTAssertTrue(picker.superview?.bounds.contains(picker.frame) == true)
            for other in [surface.send, surface.attach, surface.plan] {
                XCTAssertFalse(picker.frame.intersects(other.frame), "Picker overlaps a control at \(width)pt")
            }
            // One row: every control shares the attach button's line.
            for control in [picker, surface.send, surface.plan] as [NSView] {
                XCTAssertEqual(control.frame.midY, surface.attach.frame.midY, accuracy: 1)
            }
        }
    }

    func testImmediateSubmissionActivityContinuesThroughToolsAndStreamingThenHidesAtIdle() throws {
        let surface = surface()
        surface.setActivity(status: .idle, submitting: true)
        XCTAssertTrue(surface.send.isHidden, "An empty draft offers Stop, not Send")
        XCTAssertFalse(surface.stop.isHidden)
        XCTAssertFalse(visibleLabels(surface).contains("Sending…"), "A send must not flash a card over the composer")
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude,
                                         status: .working, items: [AgentChatItem(id: "tool", kind: .tool, text: "Read source", isComplete: false)])
        surface.setActivity(status: .working, submitting: false)
        surface.render(snapshot)
        surface.composer.string = "Follow up"
        surface.refreshComposer()
        surface.layoutSubtreeIfNeeded()
        XCTAssertFalse(surface.send.isHidden, "A draft while working queues through Send")
        XCTAssertFalse(surface.stop.isHidden, "Stop remains available without discarding the draft")
        XCTAssertFalse(surface.stop.frame.intersects(surface.send.frame))
        surface.composer.string = ""
        XCTAssertFalse(visibleLabels(surface).contains("Working…"), "Working belongs in the transcript")
        snapshot.items.append(AgentChatItem(id: "answer", kind: .assistant, text: "Partial answer", isComplete: false))
        surface.render(snapshot)
        surface.layoutSubtreeIfNeeded()
        let body = try XCTUnwrap(descendants(surface.transcriptScroll).compactMap { $0 as? NSTextView }
            .first { $0.string == "Partial answer" })
        XCTAssertFalse(body.visibleRect.isEmpty, "Activity must not obscure streamed assistant text")
        XCTAssertFalse(visibleLabels(surface).contains("Working…"), "Working belongs in the transcript")
        snapshot.items[snapshot.items.count - 1].text += " grows"
        surface.render(snapshot)
        XCTAssertEqual(body.string, "Partial answer grows", "The same text view must continue updating")
        surface.setActivity(status: .waiting, submitting: false)
        XCTAssertTrue(visibleLabels(surface).contains("Waiting for approval"))
        surface.setActivity(status: .idle, submitting: false)
        XCTAssertTrue(surface.stop.isHidden)
        XCTAssertTrue(surface.send.isHidden)
        XCTAssertFalse(surface.microphone.isHidden, "Idle with an empty draft offers dictation")
        XCTAssertFalse(visibleLabels(surface).contains("Working…"))
        XCTAssertFalse(visibleLabels(surface).contains("Waiting for approval"))
    }

    func testLongStreamingAnswerFollowsEndButUserScrollAwaySurvivesGrowthAndResize() throws {
        let surface = surface()
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude,
                                         status: .working, items: [AgentChatItem(id: "answer", kind: .assistant,
                                             text: String(repeating: "A streamed line of prose.\n\n", count: 50), isComplete: false)])
        surface.render(snapshot)
        surface.layoutSubtreeIfNeeded()
        XCTAssertTrue(surface.isAtBottom)
        snapshot.items[0].text += String(repeating: "More streamed text.\n\n", count: 20)
        surface.render(snapshot)
        XCTAssertTrue(surface.isAtBottom)

        surface.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        surface.transcriptScroll.reflectScrolledClipView(surface.transcriptScroll.contentView)
        XCTAssertFalse(surface.isAtBottom)
        let before = surface.transcriptScroll.contentView.bounds.minY
        snapshot.items[0].text += String(repeating: "Still streaming.\n\n", count: 20)
        surface.render(snapshot)
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.transcriptScroll.contentView.bounds.minY, before, accuracy: 1)
        surface.frame.size.width = 360
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.transcriptScroll.contentView.bounds.minY, before, accuracy: 1)
        let end = try XCTUnwrap(descendants(surface).compactMap { $0 as? NSButton }.first { $0.title == "Scroll to end" })
        XCTAssertFalse(end.isHidden)
        end.performClick(nil)
        XCTAssertTrue(surface.isAtBottom)
        XCTAssertTrue(end.isHidden)
        snapshot.items[0].text += String(repeating: "Final streaming lines.\n\n", count: 10)
        surface.render(snapshot)
        XCTAssertTrue(surface.isAtBottom)
    }

    func testComposerGrowsToCapAndKeepsDraftWhenNarrowed() {
        let surface = surface()
        XCTAssertEqual(surface.composerScroll.frame.height, 44, accuracy: 1)
        let draft = String(repeating: "A multiline draft that should remain editable.\n", count: 40)
        surface.composer.string = draft
        surface.refreshComposer()
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.composerScroll.frame.height, 164, accuracy: 1)
        XCTAssertGreaterThan(surface.composer.frame.height, surface.composerScroll.frame.height)
        surface.frame.size.width = 360
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.composer.string, draft)
        XCTAssertEqual(surface.composerScroll.frame.height, 164, accuracy: 1)
    }

    func testBackdropUsesCurrentPaletteAfterPublishedThemeChange() async throws {
        _ = NSApplication.shared
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
        let surface = surface()
        surface.theme = theme
        let window = NSWindow(contentRect: surface.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.contentView = nil; window.close() }
        surface.updateLayer()
        XCTAssertEqual(surface.layer?.backgroundColor, theme.card.cgColor)
        theme.setSystemDark(false)
        try await Task.sleep(for: .milliseconds(20))
        // @Published announces before storing its new value. The drawing callback
        // must resolve colors after that notification rather than retain the old one.
        surface.updateLayer()
        XCTAssertEqual(surface.layer?.backgroundColor, theme.card.cgColor)
        XCTAssertEqual(surface.composer.textColor, theme.fg)
        theme.setSystemDark(true)
        try await Task.sleep(for: .milliseconds(20))
        surface.updateLayer()
        XCTAssertEqual(surface.layer?.backgroundColor, theme.card.cgColor)
        XCTAssertEqual(surface.composer.textColor, theme.fg)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func visibleLabels(_ view: NSView) -> [String] {
        descendants(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
    }
}
