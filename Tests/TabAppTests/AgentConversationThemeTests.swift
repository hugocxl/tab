import AppKit
@testable import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationThemeTests: XCTestCase {
    private func theme(background: UInt32 = 0x101020, foreground: UInt32 = 0xD0E0F0,
                       keyword: UInt32 = 0xAA33BB) -> AppTheme {
        let scheme = ColorScheme(background: RGBColor(background), foreground: RGBColor(foreground),
                                 palette: [5: RGBColor(keyword)])
        return AppTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Fixture", scheme: scheme)]),
                        darkTheme: "Fixture", systemIsDark: true)
    }

    func testThemePayloadReusesAppSemanticSyntaxAndTerminalColorsIncludingAlpha() {
        let native = theme()
        let value = AgentConversationTheme(native)
        XCTAssertEqual(value.mode, "dark")
        XCTAssertEqual(value.colors["foreground"], AgentConversationTheme.css(native.fg))
        XCTAssertEqual(value.colors["selection"], AgentConversationTheme.css(native.selection))
        XCTAssertEqual(value.colors["floating"], AgentConversationTheme.css(native.floating))
        XCTAssertEqual(value.syntax["comment"], AgentConversationTheme.css(native.syntaxColors.color(.comment)))
        XCTAssertEqual(value.syntax["keyword"], AgentConversationTheme.css(native.syntaxColors.color(.keyword)))
        XCTAssertEqual(value.ansi16.count, 16)
        XCTAssertEqual(value.ansi16[5], "#aa33bb")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(value.payload))
        XCTAssertNotEqual(value, AgentConversationTheme(theme(keyword: 0x33AABB)),
                          "A token/ANSI-only change must propagate even when the entire chrome palette is equal")
    }

    func testConversationCanvasUsesTheSamePaneBackgroundAsTerminal() {
        for dark in [false, true] {
            let scheme = ColorScheme(background: RGBColor(dark ? 0x102030 : 0xF0E0D0),
                                     foreground: RGBColor(dark ? 0xD0E0F0 : 0x203040))
            let native = AppTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Canvas", scheme: scheme)]),
                                  darkTheme: "Canvas", lightTheme: "Canvas", systemIsDark: dark)
            let conversation = AgentConversationTheme(native)
            let terminal = TerminalPalette(scheme: native.scheme, options: TerminalOptions(),
                                           dark: !native.palette.isLight, background: RGBColor(native.card))
            XCTAssertEqual(conversation.colors["background"], AgentConversationTheme.css(native.card))
            XCTAssertEqual(terminal.background, RGBColor(native.card).value)
            if dark {
                XCTAssertNotEqual(conversation.colors["background"], AgentConversationTheme.css(native.bg),
                                  "The dark window canvas differs from the shared terminal/agent pane canvas")
            }
        }
    }

    func testActualWKUpdatesSameModePaletteAndSyntaxWithoutReloadingConversation() async throws {
        _ = NSApplication.shared
        let host = AgentConversationWebView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
        host.layoutSubtreeIfNeeded()
        defer { host.dispose(); window.close() }
        var readyCount = 0
        var errors: [String] = []
        host.onReady = { readyCount += 1 }
        host.onFailure = { errors.append($0) }
        let snapshot = AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .codex,
            status: .idle, revision: 1, items: [.init(id: "answer", kind: .assistant, text: "Retained themed answer")])
        let first = theme()
        host.update(snapshot, theme: first, cwd: nil)
        let ready = await ModelFixtures.wait(10) { host.isReady && host.lastDeliveredRevision == 1 }
        XCTAssertTrue(ready, "Renderer ready: \(errors)")
        guard ready else { return }
        let originalReadyCount = readyCount
        for next in [theme(background: 0x201030, foreground: 0xF0D0E0),
                     theme(background: 0x201030, foreground: 0xF0D0E0, keyword: 0x33AABB),
                     AppTheme(systemIsDark: false)] {
            let expected = AgentConversationTheme(next)
            host.updateTheme(next)
            var applied = false
            for _ in 0..<100 {
                let result = try await host.evaluate("""
                    const snapshot = window.TabConversation.snapshot;
                    const canvas = document.querySelector('[data-native-canvas-clip] .bg-background');
                    const probe = document.createElement('div');
                    probe.style.backgroundColor = background;
                    document.body.appendChild(probe);
                    const expectedCanvas = getComputedStyle(probe).backgroundColor;
                    probe.remove();
                    return snapshot?.theme === mode
                      && snapshot?.palette?.background === background
                      && canvas != null && getComputedStyle(canvas).backgroundColor === expectedCanvas
                      && snapshot?.palette?.foreground === foreground
                      && snapshot?.palette?.syntax?.keyword === keyword
                      && snapshot?.palette?.ansi16?.[5] === ansi
                      && getComputedStyle(document.documentElement).getPropertyValue('--foreground').trim() === foreground
                      && document.body.textContent.includes('Retained themed answer');
                    """, arguments: ["mode": expected.mode, "background": expected.colors["background"] ?? "",
                                     "foreground": expected.colors["foreground"] ?? "",
                                     "keyword": expected.syntax["keyword"] ?? "", "ansi": expected.ansi16[5]]) as? Bool
                if result == true { applied = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(applied, "Same-mode palette must update actual source CSS and syntax: \(errors)")
            guard applied else { return }
        }
        XCTAssertEqual(readyCount, originalReadyCount, "Theme changes must not reload the renderer")
        XCTAssertEqual(host.lastDeliveredRevision, 1)
        XCTAssertTrue(errors.isEmpty)
    }
}
