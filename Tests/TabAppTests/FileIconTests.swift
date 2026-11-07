import AppKit
import XCTest
import TabCore
@testable import TabApp

@MainActor
final class FileIconTests: XCTestCase {
    func testResolutionMatchesSourceBrowserExamples() {
        let cases: [(String, String)] = [
            ("main.swift", "file-tree-builtin-swift"),
            ("src/Widget.test.tsx", "file-tree-builtin-react"),
            ("types/window.d.ts", "file-tree-builtin-typescript"),
            (".gitignore", "file-tree-builtin-git"),
            ("Dockerfile", "file-tree-builtin-docker"),
            ("AGENTS.md", "tab-file-icon-agents"),
            ("package.json", "file-tree-builtin-npm"),
            ("PNPM-LOCK.YAML", "tab-file-icon-pnpm"),
            ("run.ps1", "tab-file-icon-powershell"),
            ("unknown.xyz", "file-tree-builtin-default"),
            ("notes.txt", "file-tree-builtin-text"),
            ("schema.xml", "tab-file-icon-xml"),
            ("value.toml", "tab-file-icon-toml"),
            ("report.csv", "tab-file-icon-spreadsheet"),
        ]
        for (path, expected) in cases { XCTAssertEqual(FileIcon.name(for: path), expected, path) }
        XCTAssertEqual(FileIcon.syntheticFileName(language: "TYPESCRIPT"), "file.ts")
        XCTAssertEqual(FileIcon.syntheticFileName(language: "dockerfile"), "Dockerfile")
        XCTAssertTrue(FileIcon.hasSpecificIcon(for: FileIcon.syntheticFileName(language: "plaintext")))
        XCTAssertFalse(FileIcon.hasSpecificIcon(for: FileIcon.syntheticFileName(language: "unknown")))
    }

    func testMimeFallbackOnlyReplacesUnknownFilenameIcons() {
        XCTAssertEqual(FileIcon.name(for: "download", mimeType: "application/pdf"), "tab-file-icon-pdf")
        XCTAssertEqual(FileIcon.name(for: "unknown.xyz", mimeType: "image/png"), "file-tree-builtin-image")
        XCTAssertEqual(FileIcon.name(for: "main.swift", mimeType: "application/pdf"), "file-tree-builtin-swift")
        XCTAssertEqual(FileIcon.name(for: "download", mimeType: "APPLICATION/PDF"), "file-tree-builtin-default")
        XCTAssertEqual(FileIcon.name(for: "download", mimeType: "text/javascript; charset=utf-8"), "file-tree-builtin-default")
    }

    func testRemotePathsCachingAndDirectoriesWithFileExtensions() throws {
        let light = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let dark = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
        let swift = try XCTUnwrap(FileIcon.image(for: "/remote/nonexistent/main.swift", theme: dark))
        XCTAssertTrue(swift === FileIcon.image(for: "main.swift", theme: dark))
        XCTAssertFalse(swift.isTemplate)
        XCTAssertFalse(swift === FileIcon.image(for: "main.swift", theme: light))
        XCTAssertNotNil(FileIcon.image(for: "unknown.xyz", theme: dark))
        let folder = try XCTUnwrap(FileIcon.image(for: "/remote/package.swift", isDirectory: true, theme: dark))
        XCTAssertTrue(folder === FileIcon.image(for: "/remote/src", isDirectory: true, theme: dark))
        XCTAssertFalse(folder === swift)
    }

    func testExplicitFileLinksKeepLabelsPositionsAndCopyText() throws {
        for dark in [false, true] {
            let theme = AppTheme(systemIsDark: dark)
            let content = AgentMarkdown.inline("[**Main**](Sources/main.swift:12:4) [Folder](Sources/) `main.swift`", theme: theme, fileLinks: true)
            XCTAssertEqual(content.string, "Main Folder main.swift")
            let links = AgentFileLinkHover.fileLinks(in: content)
            XCTAssertEqual(links.map(\.path), ["Sources/main.swift", "Sources/", "main.swift"])
            let image = try XCTUnwrap(content.attribute(.agentFileLinkImage, at: 0, effectiveRange: nil) as? NSImage)
            XCTAssertTrue(image === FileIcon.image(for: "Sources/main.swift", theme: theme))
            let url = try XCTUnwrap(content.attribute(.link, at: 0, effectiveRange: nil) as? URL)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "column" }?.value, "4")
            XCTAssertNotNil(content.attribute(.agentFileLinkImage, at: 5, effectiveRange: nil))
            XCTAssertNil(content.attribute(.agentFileLinkImage, at: 12, effectiveRange: nil), "Inferred inline code keeps its existing treatment")
        }
    }

    func testCachedMetadataRefinesDirectoryAndMimeIconsWithoutChangingLinks() throws {
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: true)
        let text = NSMutableAttributedString(attributedString: AgentMarkdown.inline("[Download](download.bin)", theme: theme, fileLinks: true))
        // A directory destination without a slash is valid when the metadata identifies it.
        let directoryURL = try XCTUnwrap(AgentResponseLink.fileURL(path: "Sources", line: nil))
        // Markdown only treats recognizable paths as files; use the canonical link for this folder.
        let canonical = NSMutableAttributedString(string: "Sources", attributes: [
            .link: directoryURL, .agentExternalLinkIdentity: "directory", .font: AppFont.system(14),
        ])
        AgentExternalLinkLayout.mark(canonical, fontSize: 14, color: theme.accent, theme: theme)
        AgentFileLinkTooltip.markIcons(canonical, theme: theme) { _ in .init(isDirectory: true, byteLength: 0, mimeType: nil) }
        let image = try XCTUnwrap(canonical.attribute(.agentFileLinkImage, at: 0, effectiveRange: nil) as? NSImage)
        XCTAssertTrue(image === FileIcon.image(for: "Sources", isDirectory: true, theme: theme))
        XCTAssertEqual(canonical.string, "Sources")
        XCTAssertEqual(canonical.attribute(.link, at: 0, effectiveRange: nil) as? URL, directoryURL)
        AgentFileLinkTooltip.markIcons(text, theme: theme) { path in
            path == "download.bin" ? .init(isDirectory: false, byteLength: 1, mimeType: "application/pdf") : nil
        }
        let download = (text.string as NSString).range(of: "Download")
        let pdf = try XCTUnwrap(text.attribute(.agentFileLinkImage, at: download.location, effectiveRange: nil) as? NSImage)
        XCTAssertTrue(pdf === FileIcon.image(for: "report.pdf", theme: theme))
    }

    func testEveryBundledIconVariantRendersNativePixels() throws {
        let url = try XCTUnwrap(BundledImage.url("agent-file-icons", extension: "json"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let icons = try XCTUnwrap(catalog["icons"] as? [String: [String]])
        for (name, variants) in icons {
            for svg in variants {
                let image = try XCTUnwrap(NSImage(data: Data(svg.utf8)), name)
                let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), name)
                let visible = (0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
                }
                XCTAssertTrue(visible, name)
            }
        }
    }
}
