import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentComposerSurfaceTests: XCTestCase {
    private func surface(width: CGFloat = 680) -> AgentPaneView {
        let surface = AgentPaneView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        surface.model.addItem(withTitle: "A custom model with a very long name")
        surface.effort.addItem(withTitle: "Extra high")
        surface.access.addItem(withTitle: "Full access")
        surface.layoutSubtreeIfNeeded()
        return surface
    }

    func testAllThreeNativePickersRemainAccessibleInNarrowAndWideSplits() {
        for width in [CGFloat(360), 560, 680, 1000] {
            let surface = surface(width: width)
            let controls = [surface.model, surface.effort, surface.access]
            for control in controls {
                XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
                XCTAssertGreaterThanOrEqual(control.frame.width, 70)
                XCTAssertEqual(control.frame.height, 26)
                XCTAssertTrue(control.superview?.bounds.contains(control.frame) == true)
                XCTAssertFalse(control.frame.intersects(surface.send.frame), "Picker must not cover Send at \(width)pt")
                XCTAssertNotNil(control.toolTip)
            }
            for index in controls.indices {
                for other in controls.indices where other > index {
                    XCTAssertFalse(controls[index].frame.intersects(controls[other].frame))
                }
            }
            if width == 360 {
                XCTAssertGreaterThan(surface.access.frame.minY, surface.model.frame.minY)
            }
        }
    }

    func testImmediateSubmissionActivityContinuesThroughToolsAndStreamingThenHidesAtIdle() throws {
        let surface = surface()
        surface.setActivity(status: .idle, submitting: true)
        XCTAssertTrue(surface.send.isHidden)
        XCTAssertFalse(surface.stop.isHidden)
        XCTAssertTrue(visibleLabels(surface).contains("Sending…"))
        var snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude,
                                         status: .working, items: [AgentChatItem(id: "tool", kind: .tool, text: "Read source", isComplete: false)])
        surface.setActivity(status: .working, submitting: false)
        surface.render(snapshot)
        XCTAssertTrue(visibleLabels(surface).contains("Working…"))
        snapshot.items.append(AgentChatItem(id: "answer", kind: .assistant, text: "Partial answer", isComplete: false))
        surface.render(snapshot)
        surface.layoutSubtreeIfNeeded()
        let body = try XCTUnwrap(descendants(surface.transcriptScroll).compactMap { $0 as? NSTextView }
            .first { $0.string == "Partial answer" })
        XCTAssertFalse(body.visibleRect.isEmpty, "Activity must not obscure streamed assistant text")
        XCTAssertTrue(visibleLabels(surface).contains("Working…"))
        snapshot.items[snapshot.items.count - 1].text += " grows"
        surface.render(snapshot)
        XCTAssertEqual(body.string, "Partial answer grows", "The same text view must continue updating")
        surface.setActivity(status: .waiting, submitting: false)
        XCTAssertTrue(visibleLabels(surface).contains("Waiting for approval"))
        surface.setActivity(status: .idle, submitting: false)
        XCTAssertTrue(surface.stop.isHidden)
        XCTAssertFalse(surface.send.isHidden)
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
        XCTAssertEqual(surface.composerScroll.frame.height, 56, accuracy: 1)
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
        XCTAssertFalse(surface.access.isHiddenOrHasHiddenAncestor)
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
