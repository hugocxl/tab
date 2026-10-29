import Foundation

/// What a highlighted range is.
public enum TokenKind: UInt8, CaseIterable, Sendable {
    case keyword, string, comment, number, type, function, attribute, punctuation
}

/// A highlighted range of the text, in UTF-16 offsets as `NSRange`s use.
public struct TokenRange: Equatable, Sendable {
    public var range: NSRange
    public var kind: TokenKind

    public init(_ range: NSRange, _ kind: TokenKind) {
        self.range = range
        self.kind = kind
    }

    public init(location: Int, length: Int, kind: TokenKind) {
        self.init(NSRange(location: location, length: length), kind)
    }
}

/// What carries from one line to the next: an open block comment, string,
/// tag or code fence, and a nesting depth.
struct LineState: Hashable, Sendable {
    enum Mode: Hashable, Sendable {
        case normal
        /// Inside a block comment; `depth` counts nesting.
        case comment
        /// Inside the multi-line string of rule `n`.
        case string(Int)
        /// Inside an HTML or XML tag spanning lines.
        case tag
        /// Inside a Markdown code fence.
        case fence
    }

    var mode: Mode = .normal
    /// Nested block comments, or CSS braces.
    var depth = 0

    static let start = LineState()
}

/// A string delimiter pair.
struct StringRule: Sendable {
    let open: [UInt16]
    let close: [UInt16]
    let escapes: Bool
    let multiline: Bool

    init(_ open: String, _ close: String? = nil, escapes: Bool = true, multiline: Bool = false) {
        self.open = Array(open.utf16)
        self.close = Array((close ?? open).utf16)
        self.escapes = escapes
        self.multiline = multiline
    }
}

/// A C-like language's lexical rules.
struct Grammar: Sendable {
    var keywords: Set<String>
    var types: Set<String> = []
    /// Constants such as `true` and `nil`, colored like numbers.
    var literals: Set<String> = ["true", "false"]
    var lineComments: [String] = ["//"]
    var blockComment: (open: String, close: String)? = ("/*", "*/")
    var nestedComments = false
    var strings: [StringRule] = [StringRule("\""), StringRule("'")]
    /// Characters that start an attribute or decorator such as `@main`.
    var attributePrefixes: Set<UInt16> = []
    /// Rust's `#[derive(...)]`.
    var bracketAttributes = false
    /// C's `#include` at the start of a line.
    var preprocessor = false
    /// Swift's `#if`, `#available`.
    var hashKeywords = false
    var capitalizedTypes = true
    var caseInsensitive = false
    /// Shell's `$name`, `${name}` and `$(…)`.
    var dollarVariables = false
    var dollarInIdentifiers = false
    /// Rust's `name!(…)` macros and `'a` lifetimes.
    var rustMacros = false
    /// JSX tags such as `<View>`.
    var jsxTags = false
    /// Ruby's `:symbol` and `@ivar`.
    var rubySymbols = false
    /// A `#` starts a comment only at a word boundary, as in shell.
    var hashCommentNeedsBoundary = false
    /// The first word of a line is an instruction, as in a Dockerfile.
    var lineInstructions: Set<String> = []
}

enum Grammars {
    static let swift = Grammar(
        keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
            "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static",
            "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do", "else",
            "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while", "as", "is",
            "super", "self", "Self", "throws", "try", "async", "await", "actor", "nonisolated", "isolated", "some", "any",
            "convenience", "dynamic", "final", "lazy", "mutating", "nonmutating", "optional", "override", "required",
            "unowned", "weak", "willSet", "didSet", "get", "set", "indirect", "consuming", "borrowing", "package", "macro",
        ],
        literals: ["true", "false", "nil"],
        nestedComments: true,
        strings: [StringRule("\"\"\"", multiline: true), StringRule("\"")],
        attributePrefixes: [utf16Unit("@")],
        hashKeywords: true
    )

    static let rust = Grammar(
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for",
            "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
            "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while", "yield", "union", "macro_rules",
        ],
        types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str"],
        literals: ["true", "false", "None", "Some", "Ok", "Err"],
        nestedComments: true,
        strings: [StringRule("\"", multiline: true)],
        bracketAttributes: true,
        rustMacros: true
    )

    static let c = Grammar(
        keywords: [
            "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if",
            "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef", "union",
            "volatile", "while", "_Bool", "_Atomic", "_Noreturn", "_Static_assert", "_Thread_local", "alignas", "alignof",
        ],
        types: [
            "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "size_t", "ssize_t",
            "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "uintptr_t", "FILE",
        ],
        literals: ["true", "false", "NULL", "nullptr"],
        preprocessor: true,
        capitalizedTypes: false
    )

    static let cpp: Grammar = {
        var grammar = c
        grammar.keywords.formUnion([
            "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "final",
            "new", "delete", "this", "operator", "friend", "using", "try", "catch", "throw", "noexcept", "constexpr",
            "consteval", "constinit", "decltype", "explicit", "mutable", "static_cast", "dynamic_cast", "reinterpret_cast",
            "const_cast", "co_await", "co_return", "co_yield", "concept", "requires", "export", "module", "import",
        ])
        grammar.types.formUnion(["auto", "wchar_t", "char8_t", "char16_t", "char32_t", "string"])
        grammar.capitalizedTypes = true
        return grammar
    }()

    static let objectiveC: Grammar = {
        var grammar = cpp
        grammar.keywords.formUnion(["self", "super", "id", "instancetype", "nonatomic", "atomic", "strong", "weak", "copy", "assign", "readonly", "readwrite", "nullable", "nonnull"])
        grammar.literals.formUnion(["YES", "NO", "nil", "Nil"])
        grammar.strings = [StringRule("@\""), StringRule("\""), StringRule("'")]
        grammar.attributePrefixes = [utf16Unit("@")]
        return grammar
    }()

    static let go = Grammar(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
            "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
        ],
        types: [
            "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32",
            "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any",
        ],
        literals: ["true", "false", "nil", "iota"],
        strings: [StringRule("`", escapes: false, multiline: true), StringRule("\""), StringRule("'")]
    )

    static let python = Grammar(
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
            "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
            "raise", "return", "try", "while", "with", "yield", "match", "case", "self", "cls",
        ],
        types: ["int", "float", "str", "bytes", "bool", "list", "dict", "set", "tuple", "object", "type"],
        literals: ["True", "False", "None"],
        lineComments: ["#"],
        blockComment: nil,
        strings: [
            StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true), StringRule("\""), StringRule("'"),
        ],
        attributePrefixes: [utf16Unit("@")]
    )

    static let ruby = Grammar(
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure",
            "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then",
            "undef", "unless", "until", "when", "while", "yield", "require", "require_relative", "attr_reader",
            "attr_writer", "attr_accessor", "private", "protected", "public", "lambda", "proc",
        ],
        literals: ["true", "false", "nil"],
        lineComments: ["#"],
        blockComment: nil,
        strings: [StringRule("\"", multiline: true), StringRule("'", multiline: true), StringRule("`")],
        rubySymbols: true
    )

    static let javaScript = Grammar(
        keywords: [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
            "else", "export", "extends", "finally", "for", "from", "function", "get", "if", "import", "in", "instanceof",
            "let", "new", "of", "return", "set", "static", "super", "switch", "this", "throw", "try", "typeof", "var",
            "void", "while", "with", "yield", "as",
        ],
        literals: ["true", "false", "null", "undefined", "NaN", "Infinity"],
        strings: [StringRule("`", multiline: true), StringRule("\""), StringRule("'")],
        attributePrefixes: [utf16Unit("@")],
        dollarInIdentifiers: true
    )

    static let typeScript: Grammar = {
        var grammar = javaScript
        grammar.keywords.formUnion([
            "abstract", "declare", "enum", "implements", "interface", "keyof", "module", "namespace", "private",
            "protected", "public", "readonly", "type", "infer", "is", "asserts", "satisfies", "override", "unique",
        ])
        grammar.types = ["string", "number", "boolean", "any", "unknown", "never", "void", "object", "symbol", "bigint"]
        return grammar
    }()

    static let jsx: Grammar = {
        var grammar = javaScript
        grammar.jsxTags = true
        return grammar
    }()

    static let tsx: Grammar = {
        var grammar = typeScript
        grammar.jsxTags = true
        return grammar
    }()

    static let sql = Grammar(
        keywords: [
            "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create",
            "table", "drop", "alter", "add", "column", "index", "view", "join", "inner", "left", "right", "outer", "full",
            "cross", "on", "as", "group", "by", "order", "having", "limit", "offset", "union", "all", "distinct", "case",
            "when", "then", "else", "end", "in", "is", "like", "between", "exists", "primary", "key", "foreign",
            "references", "unique", "default", "constraint", "check", "begin", "commit", "rollback", "transaction",
            "with", "returning", "if", "asc", "desc", "trigger", "function", "procedure", "return", "returns", "declare",
            "cascade", "using", "pragma", "replace", "conflict", "do", "nothing", "autoincrement",
        ],
        types: [
            "int", "integer", "bigint", "smallint", "text", "varchar", "char", "boolean", "bool", "real", "float", "double",
            "decimal", "numeric", "date", "time", "timestamp", "timestamptz", "blob", "json", "jsonb", "uuid", "serial",
        ],
        literals: ["true", "false", "null"],
        lineComments: ["--"],
        strings: [StringRule("'"), StringRule("\"")],
        capitalizedTypes: false,
        caseInsensitive: true
    )

    static let shell = Grammar(
        keywords: [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function",
            "select", "time", "return", "exit", "export", "local", "readonly", "declare", "typeset", "unset", "source",
            "alias", "set", "shift", "trap", "eval", "exec", "break", "continue", "end",
        ],
        literals: ["true", "false"],
        lineComments: ["#"],
        blockComment: nil,
        strings: [StringRule("\"", multiline: true), StringRule("'", escapes: false, multiline: true)],
        capitalizedTypes: false,
        dollarVariables: true,
        hashCommentNeedsBoundary: true
    )

    static let dockerfile: Grammar = {
        var grammar = shell
        grammar.lineInstructions = [
            "from", "run", "cmd", "label", "maintainer", "expose", "env", "add", "copy", "entrypoint", "volume", "user",
            "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell",
        ]
        return grammar
    }()

    static func grammar(_ language: SyntaxLanguage) -> Grammar? {
        switch language {
        case .swift: return swift
        case .rust: return rust
        case .c: return c
        case .cpp: return cpp
        case .objectiveC: return objectiveC
        case .go: return go
        case .python: return python
        case .ruby: return ruby
        case .javaScript: return javaScript
        case .typeScript: return typeScript
        case .jsx: return jsx
        case .tsx: return tsx
        case .sql: return sql
        case .shell: return shell
        case .dockerfile: return dockerfile
        case .json, .yaml, .toml, .markdown, .html, .xml, .css, .makefile, .plain: return nil
        }
    }
}

/// The UTF-16 code unit of an ASCII character.
@inline(__always)
func utf16Unit(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }
