import Foundation

/// A language the editor highlights.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, rust, c, cpp, objectiveC, go, python, ruby
    case javaScript, typeScript, jsx, tsx
    case json, yaml, toml, markdown, html, xml, css
    case shell, sql, dockerfile, makefile
    case plain

    /// The language of a file by its name or extension; `plain` when unknown.
    public static func detect(fileName: String) -> SyntaxLanguage {
        let name = (fileName as NSString).lastPathComponent
        let lower = name.lowercased()
        if let language = byName[lower] { return language }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") || lower.hasPrefix("containerfile") { return .dockerfile }
        if lower.hasPrefix("makefile") || lower == "gnumakefile" { return .makefile }
        if lower.hasPrefix(".env") { return .shell }
        let ext = (lower as NSString).pathExtension
        return byExtension[ext] ?? .plain
    }

    /// Picks a language from a `#!` line when the name says nothing.
    public static func detect(fileName: String, firstLine: String) -> SyntaxLanguage {
        let language = detect(fileName: fileName)
        guard language == .plain, firstLine.hasPrefix("#!") else { return language }
        for (needle, match) in [("python", SyntaxLanguage.python), ("ruby", .ruby), ("node", .javaScript), ("sh", .shell)]
            where firstLine.contains(needle)
        {
            return match
        }
        return language
    }

    private static let byName: [String: SyntaxLanguage] = [
        "makefile": .makefile, "gnumakefile": .makefile, "dockerfile": .dockerfile, "containerfile": .dockerfile,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "brewfile": .ruby, "vagrantfile": .ruby,
        "package.swift": .swift, "cargo.lock": .toml, ".bashrc": .shell, ".zshrc": .shell, ".profile": .shell,
        ".bash_profile": .shell, ".zprofile": .shell, ".gitconfig": .toml, "pipfile": .toml,
    ]

    private static let byExtension: [String: SyntaxLanguage] = [
        "swift": .swift, "rs": .rust,
        "c": .c, "h": .c, "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "ino": .cpp,
        "m": .objectiveC, "mm": .objectiveC,
        "go": .go, "py": .python, "pyi": .python, "pyw": .python, "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "js": .javaScript, "mjs": .javaScript, "cjs": .javaScript, "ts": .typeScript, "mts": .typeScript, "cts": .typeScript,
        "jsx": .jsx, "tsx": .tsx,
        "json": .json, "jsonc": .json, "json5": .json, "geojson": .json, "webmanifest": .json,
        "yaml": .yaml, "yml": .yaml, "toml": .toml,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown,
        "html": .html, "htm": .html, "xhtml": .html, "vue": .html, "svelte": .html,
        "xml": .xml, "plist": .xml, "svg": .xml, "xib": .xml, "storyboard": .xml, "xsd": .xml, "xsl": .xml,
        "css": .css, "scss": .css, "sass": .css, "less": .css,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "ksh": .shell, "command": .shell,
        "sql": .sql, "psql": .sql, "mk": .makefile, "mak": .makefile, "dockerfile": .dockerfile,
    ]
}
