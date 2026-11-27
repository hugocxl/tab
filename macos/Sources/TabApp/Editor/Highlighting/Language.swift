import Foundation

/// A language the editor highlights.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, rust, c, cpp, objectiveC, go, python, ruby
    case javaScript, typeScript, jsx, tsx
    case json, yaml, toml, markdown, html, xml, css
    case shell, sql, dockerfile, makefile
    case java, kotlin, csharp, fsharp, php, scala, dart, lua, perl, r, julia
    case haskell, elixir, erlang, clojure, lisp, zig, nim, groovy, powershell, vim
    case ini, diff, graphql, protobuf, terraform, nginx, latex, bat, applescript
    case matlab, fortran, ocaml, elm, solidity, cmake, nix, prisma, wat, gleam
    case crystal, v, odin, shader, asm, log, http
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
        ".bash_profile": .shell, ".zprofile": .shell, ".gitconfig": .ini, "pipfile": .toml,
        ".editorconfig": .ini, ".npmrc": .ini, ".vimrc": .vim, "_vimrc": .vim, "init.vim": .vim, "jenkinsfile": .groovy,
        "cmakelists.txt": .cmake, "nginx.conf": .nginx, "build.gradle": .groovy,
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
        "java": .java, "kt": .kotlin, "kts": .kotlin, "cs": .csharp, "csx": .csharp, "fs": .fsharp, "fsx": .fsharp,
        "fsi": .fsharp, "php": .php, "phtml": .php, "scala": .scala, "sc": .scala, "sbt": .scala, "dart": .dart,
        "lua": .lua, "pl": .perl, "pm": .perl, "t": .perl, "r": .r, "jl": .julia, "hs": .haskell, "lhs": .haskell,
        "ex": .elixir, "exs": .elixir, "erl": .erlang, "hrl": .erlang, "clj": .clojure, "cljs": .clojure,
        "cljc": .clojure, "edn": .clojure, "lisp": .lisp, "lsp": .lisp, "cl": .lisp, "scm": .lisp, "ss": .lisp,
        "rkt": .lisp, "el": .lisp, "zig": .zig, "nim": .nim, "nims": .nim, "groovy": .groovy, "gradle": .groovy,
        "ps1": .powershell, "psm1": .powershell, "psd1": .powershell, "vim": .vim, "ini": .ini, "cfg": .ini,
        "conf": .ini, "properties": .ini, "editorconfig": .ini, "gitconfig": .ini, "diff": .diff, "patch": .diff,
        "graphql": .graphql, "gql": .graphql, "proto": .protobuf, "tf": .terraform, "tfvars": .terraform,
        "hcl": .terraform, "tex": .latex, "sty": .latex, "cls": .latex, "bat": .bat, "cmd": .bat,
        "applescript": .applescript, "scpt": .applescript, "f": .fortran, "f90": .fortran, "f95": .fortran,
        "f03": .fortran, "for": .fortran, "ml": .ocaml, "mli": .ocaml, "elm": .elm, "sol": .solidity,
        "cmake": .cmake, "nix": .nix, "prisma": .prisma, "wat": .wat, "gleam": .gleam, "cr": .crystal, "v": .v,
        "odin": .odin, "glsl": .shader, "hlsl": .shader, "wgsl": .shader, "metal": .shader, "frag": .shader,
        "vert": .shader, "comp": .shader, "asm": .asm, "s": .asm, "nasm": .asm, "log": .log, "http": .http,
        "rest": .http, "astro": .html, "jsonl": .json,
    ]

    /// The language of a Markdown fence's info string: its first word,
    /// lowercased, through the usual aliases (`ts`, `sh`, `c++`, `yml`);
    /// `plain` when unknown.
    public static func forFence(_ info: String) -> SyntaxLanguage {
        let separators: Set<Character> = [" ", "\t", "{", ","]
        guard let word = info.split(whereSeparator: { separators.contains($0) }).first else { return .plain }
        var key = word.lowercased()
        if key.hasPrefix("language-") { key.removeFirst("language-".count) }
        return fenceAliases[key] ?? .plain
    }

    private static let fenceAliases: [String: SyntaxLanguage] = {
        let groups: [(SyntaxLanguage, String)] = [
            (.swift, "swift"), (.rust, "rust rs"), (.c, "c h"), (.cpp, "c++ cpp cc cxx hpp"),
            (.objectiveC, "objc objective-c objectivec objective-c++ objc++ m mm"), (.go, "go golang"),
            (.python, "py python python3 py3 pyi"), (.ruby, "rb ruby rake gemspec"),
            (.javaScript, "js javascript mjs cjs node"), (.typeScript, "ts typescript mts cts"),
            (.jsx, "jsx"), (.tsx, "tsx"), (.json, "json jsonc json5 jsonl geojson"),
            (.yaml, "yml yaml"), (.toml, "toml"), (.markdown, "md markdown mdx"),
            (.html, "html htm xhtml vue svelte astro"), (.xml, "xml plist svg xsd xsl xib storyboard"),
            (.css, "css scss sass less postcss"), (.shell, "sh shell bash zsh fish console shellsession shellscript ksh"),
            (.sql, "sql mysql postgres postgresql psql sqlite plsql pgsql tsql"),
            (.dockerfile, "docker dockerfile containerfile"), (.makefile, "make makefile mk"),
            (.java, "java"), (.kotlin, "kt kotlin kts"), (.csharp, "c# cs csharp"), (.fsharp, "f# fsharp fs"),
            (.php, "php"), (.scala, "scala sbt sc"), (.dart, "dart"), (.lua, "lua"), (.perl, "pl perl pm"),
            (.r, "r"), (.julia, "jl julia"), (.haskell, "hs haskell"), (.elixir, "ex exs elixir"),
            (.erlang, "erl erlang"), (.clojure, "clj cljs cljc clojure edn"),
            (.lisp, "lisp scheme racket el emacs-lisp elisp commonlisp scm rkt"), (.zig, "zig"), (.nim, "nim"),
            (.groovy, "groovy gradle"), (.powershell, "ps1 powershell pwsh"), (.vim, "vim viml vimscript"),
            (.ini, "ini cfg conf properties editorconfig gitconfig"), (.diff, "diff patch udiff"),
            (.graphql, "graphql gql"), (.protobuf, "proto protobuf proto3"), (.terraform, "tf terraform hcl tfvars"),
            (.nginx, "nginx"), (.latex, "tex latex"), (.bat, "bat cmd batch"), (.applescript, "applescript osascript"),
            (.matlab, "matlab octave"), (.fortran, "f90 f95 f03 fortran"), (.ocaml, "ml ocaml"), (.elm, "elm"),
            (.solidity, "sol solidity"), (.cmake, "cmake"), (.nix, "nix"), (.prisma, "prisma"),
            (.wat, "wat wasm wast"), (.gleam, "gleam"), (.crystal, "cr crystal"), (.v, "v vlang"),
            (.odin, "odin"), (.shader, "glsl hlsl wgsl metal shader frag vert"),
            (.asm, "asm nasm s x86asm arm armasm gas assembly"), (.log, "log"), (.http, "http https rest"),
            (.plain, "txt text plain plaintext csv tsv"),
        ]
        var table: [String: SyntaxLanguage] = [:]
        for (language, names) in groups {
            for name in names.split(separator: " ") { table[String(name)] = language }
        }
        return table
    }()
}
