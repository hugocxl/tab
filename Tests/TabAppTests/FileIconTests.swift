import AppKit
import XCTest
import TabCore
@testable import TabApp

@MainActor
final class FileIconTests: XCTestCase {
    func testResolutionMatchesSourceBrowserExamples() {
        let cases: [(String, String)] = [
            ("main.swift", "swift"),
            ("src/Widget.test.tsx", "react"),
            ("types/window.d.ts", "typescript"),
            (".gitignore", "git"),
            ("Dockerfile", "docker"),
            ("AGENTS.md", "agents"),
            ("package.json", "npm"),
            ("PNPM-LOCK.YAML", "pnpm"),
            ("run.ps1", "powershell"),
            ("unknown.xyz", "file"),
            ("notes.txt", "file-text"),
            ("schema.xml", "xml"),
            ("value.toml", "toml"),
            ("report.csv", "file-table"),
        ]
        for (path, expected) in cases { XCTAssertEqual(FileIcon.name(for: path), expected, path) }
        XCTAssertEqual(FileIcon.syntheticFileName(language: "TYPESCRIPT"), "file.ts")
        XCTAssertEqual(FileIcon.syntheticFileName(language: "dockerfile"), "Dockerfile")
        XCTAssertTrue(FileIcon.hasSpecificIcon(for: FileIcon.syntheticFileName(language: "plaintext")))
        XCTAssertFalse(FileIcon.hasSpecificIcon(for: FileIcon.syntheticFileName(language: "unknown")))
    }

    func testMimeFallbackOnlyReplacesUnknownFilenameIcons() {
        XCTAssertEqual(FileIcon.name(for: "download", mimeType: "application/pdf"), "pdf")
        XCTAssertEqual(FileIcon.name(for: "unknown.xyz", mimeType: "image/png"), "image")
        XCTAssertEqual(FileIcon.name(for: "main.swift", mimeType: "application/pdf"), "swift")
        XCTAssertEqual(FileIcon.name(for: "download", mimeType: "APPLICATION/PDF"), "file")
        XCTAssertEqual(FileIcon.name(for: "download", mimeType: "text/javascript; charset=utf-8"), "file")
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
        XCTAssertTrue(folder === AppIcon.folder.image(size: 14, hue: .gray, theme: dark))
        let openFolder = try XCTUnwrap(FileIcon.image(for: "/remote/package.swift", isDirectory: true, isExpanded: true, theme: dark))
        XCTAssertTrue(openFolder === AppIcon.folderOpen.image(size: 14, hue: .gray, theme: dark))
        XCTAssertFalse(openFolder === folder)
        XCTAssertTrue(swift === FileIcon.image(for: "main.swift", dark: true))
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

    func testExactNamesOverridesAndLongestSuffixes() {
        let cases: [(String, AppIcon, AppTheme.IconHue)] = [
            (".prettierrc.toml", .prettier, .teal),
            ("package.json", .npm, .red),
            ("tsconfig.json", .typescript, .blue),
            ("PNPM-LOCK.YAML", .pnpm, .orange),
            ("types/window.d.ts", .typescript, .blue),
            ("src/Widget.test.ts", .typescript, .blue),
            ("src/Widget.test.tsx", .react, .cyan),
            ("content.mdx.tsx", .markdown, .gray),
            ("archive.env.local", .fileText, .gray),
            ("run.ps1", .powershell, .blue),
            ("implementation.mm", .objc, .vermilion),
            ("report.xlsx", .fileTable, .gray),
            ("document.rtf", .fileText, .gray),
        ]
        for (path, icon, hue) in cases {
            let resolved = FileIcon.resolve(path)
            XCTAssertEqual(resolved.icon, icon, path)
            XCTAssertEqual(resolved.hue, hue, path)
        }
    }

    func testEveryRuleUsesAnAppIconWithAnExplicitHue() throws {
        let tables = [FileIcon.fileNames, FileIcon.extensions, FileIcon.overrideNames,
                      FileIcon.overrideExtensions, FileIcon.languages]
        let icons = Set(tables.flatMap { $0.values }).union([.file, .folder, .folderOpen])
        for icon in icons {
            XCTAssertEqual(AppIcon(rawValue: icon.rawValue), icon)
            _ = try XCTUnwrap(FileIcon.hues[icon], "Missing hue for \(icon.rawValue)")
        }
        for (language, icon) in FileIcon.languages {
            XCTAssertEqual(FileIcon.resolve(FileIcon.syntheticFileName(language: language)).icon, icon, language)
        }
    }

    func testEveryFileRuleIconRendersNativePixelsInBothAppearances() throws {
        for dark in [false, true] {
            let theme = AppTheme(systemIsDark: dark)
            for (icon, hue) in FileIcon.hues {
                let image = try XCTUnwrap(icon.image(size: 16, hue: hue, theme: theme), icon.rawValue)
                let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)), icon.rawValue)
                let visible = (0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
                }
                XCTAssertTrue(visible, icon.rawValue)
            }
        }
    }
}
