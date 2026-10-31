import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentFileIconTests: XCTestCase {
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
        for (path, expected) in cases { XCTAssertEqual(AgentFileIcon.name(for: path), expected, path) }
        XCTAssertEqual(AgentFileIcon.syntheticFileName(language: "TYPESCRIPT"), "file.ts")
        XCTAssertEqual(AgentFileIcon.syntheticFileName(language: "dockerfile"), "Dockerfile")
        XCTAssertTrue(AgentFileIcon.hasSpecificIcon(for: AgentFileIcon.syntheticFileName(language: "plaintext")))
        XCTAssertFalse(AgentFileIcon.hasSpecificIcon(for: AgentFileIcon.syntheticFileName(language: "unknown")))
    }

    func testMimeFallbackOnlyReplacesUnknownFilenameIcons() {
        XCTAssertEqual(AgentFileIcon.name(for: "download", mimeType: "application/pdf"), "tab-file-icon-pdf")
        XCTAssertEqual(AgentFileIcon.name(for: "unknown.xyz", mimeType: "image/png"), "file-tree-builtin-image")
        XCTAssertEqual(AgentFileIcon.name(for: "main.swift", mimeType: "application/pdf"), "file-tree-builtin-swift")
        XCTAssertEqual(AgentFileIcon.name(for: "download", mimeType: "APPLICATION/PDF"), "file-tree-builtin-default")
        XCTAssertEqual(AgentFileIcon.name(for: "download", mimeType: "text/javascript; charset=utf-8"), "file-tree-builtin-default")
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
