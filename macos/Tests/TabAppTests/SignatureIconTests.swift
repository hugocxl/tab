import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class SignatureIconTests: XCTestCase {
    func testEveryFileResolverIconHasASignatureHue() {
        let rules = [FileIcon.fileNames, FileIcon.extensions, FileIcon.overrideNames,
                     FileIcon.overrideExtensions, FileIcon.languages]
        let icons = Set(rules.flatMap { $0.values }).union([.file, .folder, .folderOpen])
        for icon in icons {
            XCTAssertNotNil(icon.signatureHue, icon.rawValue)
            XCTAssertEqual(FileIcon.hues[icon], icon.signatureHue, icon.rawValue)
        }
    }

    func testEveryProviderAndHostMarkHasASignatureHue() throws {
        for provider in AgentProvider.knownCases + [.unknown("future-provider")] {
            let icon = AgentLogo.mark(provider)
            XCTAssertNotNil(icon.signatureHue, provider.rawValue)
            let image = try XCTUnwrap(AgentLogo.image(for: provider, lightBackground: false))
            XCTAssertFalse(image.isTemplate, provider.rawValue)
        }
        let favicons = AgentLinkFavicon(fetch: { _ in
            XCTFail("Git host marks must use bundled artwork")
            throw URLError(.badURL)
        })
        for (host, icon) in AgentLinkFavicon.hostMarks {
            XCTAssertEqual(AgentLinkFavicon.brand(for: host), icon.rawValue, host)
            XCTAssertNotNil(icon.signatureHue, host)
            let url = try XCTUnwrap(URL(string: "https://" + host))
            XCTAssertFalse(try XCTUnwrap(favicons.image(for: url, color: .magenta)).isTemplate, host)
        }
    }

    func testThemeRenderingPreservesSignatureColorsAndUITemplates() throws {
        let theme = AppTheme(systemIsDark: true)
        for dark in [true, false] {
            theme.setSystemDark(dark)
            for (icon, hue) in AppIcon.signatureHues {
                let image = try XCTUnwrap(icon.image(size: 16, theme: theme))
                XCTAssertFalse(image.isTemplate, icon.rawValue)
                XCTAssertEqual(image.size, NSSize(width: 16, height: 16), icon.rawValue)
                XCTAssertTrue(image === icon.image(size: 16, hue: hue, theme: theme), icon.rawValue)
                XCTAssertTrue(image === icon.image(size: 16, theme: theme, tint: .magenta), icon.rawValue)
            }
            for icon in [AppIcon.chevronDown, .close, .copy, .wrench, .globe, .terminal, .circle] {
                XCTAssertNil(icon.signatureHue, icon.rawValue)
                XCTAssertTrue(try XCTUnwrap(icon.image(size: 16, theme: theme)).isTemplate, icon.rawValue)
            }
        }
    }
}
