import Foundation

/// TeX atom classes. They decide the spacing between neighbouring atoms.
enum AgentMathAtomClass: Equatable, Sendable {
    case ord, op, bin, rel, open, close, punct, inner
}

/// The command tables of the supported KaTeX subset.
enum AgentMathSymbols {
    struct Symbol: Equatable, Sendable {
        var text: String
        var atomClass: AgentMathAtomClass
    }

    struct Accent: Equatable, Sendable {
        var character: String
        var isStretchy: Bool
    }

    /// Plain symbols: Greek letters, binary operators, relations, arrows and miscellany.
    static let symbols: [String: Symbol] = {
        var table: [String: Symbol] = [:]
        func add(_ atomClass: AgentMathAtomClass, _ pairs: [(String, String)]) {
            for (name, text) in pairs { table[name] = Symbol(text: text, atomClass: atomClass) }
        }
        add(.ord, [
            ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"), ("epsilon", "ϵ"),
            ("varepsilon", "ε"), ("zeta", "ζ"), ("eta", "η"), ("theta", "θ"), ("vartheta", "ϑ"),
            ("iota", "ι"), ("kappa", "κ"), ("varkappa", "ϰ"), ("lambda", "λ"), ("mu", "μ"),
            ("nu", "ν"), ("xi", "ξ"), ("omicron", "ο"), ("pi", "π"), ("varpi", "ϖ"), ("rho", "ρ"),
            ("varrho", "ϱ"), ("sigma", "σ"), ("varsigma", "ς"), ("tau", "τ"), ("upsilon", "υ"),
            ("phi", "ϕ"), ("varphi", "φ"), ("chi", "χ"), ("psi", "ψ"), ("omega", "ω"), ("digamma", "ϝ"),
            ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"), ("Xi", "Ξ"), ("Pi", "Π"),
            ("Sigma", "Σ"), ("Upsilon", "Υ"), ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
            ("infty", "∞"), ("partial", "∂"), ("nabla", "∇"), ("emptyset", "∅"), ("varnothing", "∅"),
            ("forall", "∀"), ("exists", "∃"), ("nexists", "∄"), ("neg", "¬"), ("lnot", "¬"),
            ("prime", "′"), ("hbar", "ℏ"), ("hslash", "ℏ"), ("ell", "ℓ"), ("Re", "ℜ"), ("Im", "ℑ"),
            ("aleph", "ℵ"), ("beth", "ℶ"), ("gimel", "ℷ"), ("wp", "℘"), ("angle", "∠"),
            ("measuredangle", "∡"), ("sphericalangle", "∢"), ("degree", "°"), ("top", "⊤"), ("bot", "⊥"),
            ("triangle", "△"), ("Box", "□"), ("square", "□"), ("blacksquare", "■"), ("Diamond", "◊"),
            ("lozenge", "◊"), ("clubsuit", "♣"), ("diamondsuit", "♢"), ("heartsuit", "♡"),
            ("spadesuit", "♠"), ("flat", "♭"), ("natural", "♮"), ("sharp", "♯"), ("checkmark", "✓"),
            ("surd", "√"), ("complement", "∁"), ("mho", "℧"), ("backslash", "\\"), ("imath", "ı"),
            ("jmath", "ȷ"), ("vdots", "⋮"), ("vert", "|"), ("Vert", "‖"), ("|", "‖"), ("#", "#"),
            ("$", "$"), ("%", "%"), ("&", "&"), ("_", "_"), ("S", "§"), ("P", "¶"), ("pounds", "£"),
            ("copyright", "©"), ("maltese", "✠"), ("eth", "ð"), ("diameter", "⌀"), ("AA", "Å"),
            ("bigstar", "★"), ("varpropto", "∝"), ("infin", "∞"), ("dag", "†"), ("ddag", "‡"),
            ("textbackslash", "\\"),
        ])
        add(.bin, [
            ("pm", "±"), ("mp", "∓"), ("times", "×"), ("div", "÷"), ("cdot", "⋅"), ("centerdot", "⋅"),
            ("ast", "∗"), ("star", "⋆"), ("circ", "∘"), ("bullet", "∙"), ("oplus", "⊕"),
            ("ominus", "⊖"), ("otimes", "⊗"), ("oslash", "⊘"), ("odot", "⊙"), ("cup", "∪"),
            ("cap", "∩"), ("sqcup", "⊔"), ("sqcap", "⊓"), ("vee", "∨"), ("lor", "∨"), ("wedge", "∧"),
            ("land", "∧"), ("setminus", "∖"), ("smallsetminus", "∖"), ("wr", "≀"), ("dagger", "†"),
            ("ddagger", "‡"), ("amalg", "⨿"), ("uplus", "⊎"), ("triangleleft", "◃"),
            ("triangleright", "▹"), ("bigtriangleup", "△"), ("bigtriangledown", "▽"), ("diamond", "⋄"),
            ("ltimes", "⋉"), ("rtimes", "⋊"), ("boxplus", "⊞"), ("boxtimes", "⊠"), ("boxminus", "⊟"),
            ("boxdot", "⊡"), ("dotplus", "∔"), ("intercal", "⊺"), ("divideontimes", "⋇"),
        ])
        add(.rel, [
            ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"), ("neq", "≠"), ("ne", "≠"),
            ("approx", "≈"), ("approxeq", "≊"), ("equiv", "≡"), ("sim", "∼"), ("simeq", "≃"),
            ("cong", "≅"), ("ncong", "≇"), ("nsim", "≁"), ("propto", "∝"), ("in", "∈"), ("notin", "∉"),
            ("ni", "∋"), ("owns", "∋"), ("subset", "⊂"), ("supset", "⊃"), ("subseteq", "⊆"),
            ("supseteq", "⊇"), ("subsetneq", "⊊"), ("supsetneq", "⊋"), ("nsubseteq", "⊈"),
            ("nsupseteq", "⊉"), ("sqsubset", "⊏"), ("sqsupset", "⊐"), ("sqsubseteq", "⊑"),
            ("sqsupseteq", "⊒"), ("ll", "≪"), ("gg", "≫"), ("lll", "⋘"), ("ggg", "⋙"),
            ("prec", "≺"), ("succ", "≻"), ("preceq", "⪯"), ("succeq", "⪰"), ("perp", "⊥"),
            ("parallel", "∥"), ("nparallel", "∦"), ("mid", "∣"), ("nmid", "∤"), ("vdash", "⊢"),
            ("dashv", "⊣"), ("models", "⊨"), ("vDash", "⊨"), ("asymp", "≍"), ("doteq", "≐"),
            ("bowtie", "⋈"), ("smile", "⌣"), ("frown", "⌢"), ("leqslant", "⩽"), ("geqslant", "⩾"),
            ("lesssim", "≲"), ("gtrsim", "≳"), ("nless", "≮"), ("ngtr", "≯"), ("nleq", "≰"),
            ("ngeq", "≱"), ("coloneqq", "≔"), ("eqqcolon", "≕"), ("coloneq", "≔"), ("triangleq", "≜"),
            ("therefore", "∴"), ("because", "∵"), ("to", "→"), ("rightarrow", "→"),
            ("leftarrow", "←"), ("gets", "←"), ("leftrightarrow", "↔"), ("Rightarrow", "⇒"),
            ("Leftarrow", "⇐"), ("Leftrightarrow", "⇔"), ("mapsto", "↦"), ("longmapsto", "⟼"),
            ("longrightarrow", "⟶"), ("longleftarrow", "⟵"), ("longleftrightarrow", "⟷"),
            ("Longrightarrow", "⟹"), ("Longleftarrow", "⟸"), ("Longleftrightarrow", "⟺"),
            ("uparrow", "↑"), ("downarrow", "↓"), ("updownarrow", "↕"), ("Uparrow", "⇑"),
            ("Downarrow", "⇓"), ("Updownarrow", "⇕"), ("nearrow", "↗"), ("searrow", "↘"),
            ("swarrow", "↙"), ("nwarrow", "↖"), ("hookrightarrow", "↪"), ("hookleftarrow", "↩"),
            ("rightharpoonup", "⇀"), ("rightharpoondown", "⇁"), ("leftharpoonup", "↼"),
            ("leftharpoondown", "↽"), ("rightleftharpoons", "⇌"), ("leftrightharpoons", "⇋"),
            ("leftrightarrows", "⇆"), ("rightleftarrows", "⇄"), ("rightrightarrows", "⇉"),
            ("leftleftarrows", "⇇"), ("leadsto", "⇝"), ("rightsquigarrow", "⇝"),
            ("twoheadrightarrow", "↠"), ("twoheadleftarrow", "↞"), ("nrightarrow", "↛"),
            ("nleftarrow", "↚"), ("nRightarrow", "⇏"), ("nLeftarrow", "⇍"), ("nleftrightarrow", "↮"),
            ("nLeftrightarrow", "⇎"), ("Lleftarrow", "⇚"), ("Rrightarrow", "⇛"),
            ("rightarrowtail", "↣"), ("leftarrowtail", "↢"), ("circlearrowleft", "↺"),
            ("circlearrowright", "↻"), ("curvearrowleft", "↶"), ("curvearrowright", "↷"),
            ("upuparrows", "⇈"), ("downdownarrows", "⇊"), ("multimap", "⊸"), ("propto", "∝"),
            ("between", "≬"), ("pitchfork", "⋔"), ("vartriangleleft", "⊲"), ("vartriangleright", "⊳"),
            ("trianglelefteq", "⊴"), ("trianglerighteq", "⊵"), ("lessgtr", "≶"), ("gtrless", "≷"),
            ("risingdotseq", "≓"), ("fallingdotseq", "≒"), ("eqcirc", "≖"), ("circeq", "≗"),
            ("bumpeq", "≏"), ("Bumpeq", "≎"), ("thicksim", "∼"), ("thickapprox", "≈"),
            ("Vdash", "⊩"), ("Vvdash", "⊪"), ("nvdash", "⊬"), ("nvDash", "⊭"), ("lneq", "⪇"),
            ("gneq", "⪈"), ("lneqq", "≨"), ("gneqq", "≩"), ("leqq", "≦"), ("geqq", "≧"),
            ("precsim", "≾"), ("succsim", "≿"), ("nprec", "⊀"), ("nsucc", "⊁"), ("Subset", "⋐"),
            ("Supset", "⋑"), ("subseteqq", "⫅"), ("supseteqq", "⫆"),
        ])
        add(.punct, [("colon", ":"), ("cdotp", "⋅"), ("ldotp", ".")])
        add(.inner, [
            ("ldots", "…"), ("dots", "…"), ("dotsc", "…"), ("dotso", "…"), ("cdots", "⋯"),
            ("dotsb", "⋯"), ("dotsm", "⋯"), ("dotsi", "⋯"), ("ddots", "⋱"),
        ])
        add(.open, [
            ("{", "{"), ("lbrace", "{"), ("langle", "⟨"), ("lfloor", "⌊"), ("lceil", "⌈"),
            ("lvert", "|"), ("lVert", "‖"), ("lbrack", "["), ("lgroup", "⟮"), ("ulcorner", "⌜"),
            ("llcorner", "⌞"),
        ])
        add(.close, [
            ("}", "}"), ("rbrace", "}"), ("rangle", "⟩"), ("rfloor", "⌋"), ("rceil", "⌉"),
            ("rvert", "|"), ("rVert", "‖"), ("rbrack", "]"), ("rgroup", "⟯"), ("urcorner", "⌝"),
            ("lrcorner", "⌟"),
        ])
        return table
    }()

    /// Large operators drawn from the math font; display style picks the larger variant.
    static let largeOperators: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭",
        "iiiint": "⨌", "oint": "∮", "oiint": "∯", "oiiint": "∰", "bigcup": "⋃", "bigcap": "⋂",
        "bigvee": "⋁", "bigwedge": "⋀", "bigoplus": "⨁", "bigotimes": "⨂", "bigodot": "⨀",
        "biguplus": "⨄", "bigsqcup": "⨆", "intop": "∫", "smallint": "∫",
    ]

    /// Operators whose scripts stay at the side even in display style.
    static let sideScriptOperators: Set<String> = ["∫", "∬", "∭", "⨌", "∮", "∯", "∰"]

    /// Function names set upright; `true` when they take limits in display style.
    static let functions: [String: (text: String, limits: Bool)] = {
        var table: [String: (text: String, limits: Bool)] = [:]
        for name in [
            "arcsin", "arccos", "arctan", "arctg", "arcctg", "arg", "ch", "cos", "cosec", "cosh", "cot",
            "cotg", "coth", "csc", "ctg", "cth", "deg", "dim", "exp", "hom", "ker", "lg", "ln", "log",
            "sec", "sh", "sin", "sinh", "sgn", "tan", "tanh", "tg", "th",
        ] {
            table[name] = (name, false)
        }
        for name in ["det", "gcd", "inf", "lim", "max", "min", "Pr", "sup", "argmax", "argmin"] {
            table[name] = (name, true)
        }
        table["liminf"] = ("lim\u{2009}inf", true)
        table["limsup"] = ("lim\u{2009}sup", true)
        table["injlim"] = ("inj\u{2009}lim", true)
        table["projlim"] = ("proj\u{2009}lim", true)
        return table
    }()

    /// Delimiter commands accepted after `\left`, `\right`, `\middle` and `\big`.
    static let delimiterCommands: [String: String] = [
        "{": "{", "}": "}", "lbrace": "{", "rbrace": "}", "|": "‖", "vert": "|", "Vert": "‖",
        "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖", "langle": "⟨", "rangle": "⟩",
        "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "lbrack": "[", "rbrack": "]",
        "lgroup": "⟮", "rgroup": "⟯", "uparrow": "↑", "downarrow": "↓", "updownarrow": "↕",
        "Uparrow": "⇑", "Downarrow": "⇓", "Updownarrow": "⇕", "backslash": "\\", "mid": "∣",
        "lmoustache": "⎰", "rmoustache": "⎱", "ulcorner": "⌜", "urcorner": "⌝",
    ]

    static let delimiterCharacters: [Character: String] = [
        "(": "(", ")": ")", "[": "[", "]": "]", "|": "|", "/": "/", "<": "⟨", ">": "⟩", ".": "",
        "⟨": "⟨", "⟩": "⟩", "‖": "‖", "⌊": "⌊", "⌋": "⌋", "⌈": "⌈", "⌉": "⌉",
    ]

    static let accents: [String: Accent] = [
        "hat": Accent(character: "\u{0302}", isStretchy: false),
        "check": Accent(character: "\u{030C}", isStretchy: false),
        "tilde": Accent(character: "\u{0303}", isStretchy: false),
        "acute": Accent(character: "\u{0301}", isStretchy: false),
        "grave": Accent(character: "\u{0300}", isStretchy: false),
        "dot": Accent(character: "\u{0307}", isStretchy: false),
        "ddot": Accent(character: "\u{0308}", isStretchy: false),
        "dddot": Accent(character: "\u{20DB}", isStretchy: false),
        "breve": Accent(character: "\u{0306}", isStretchy: false),
        "bar": Accent(character: "\u{0304}", isStretchy: false),
        "vec": Accent(character: "\u{20D7}", isStretchy: false),
        "mathring": Accent(character: "\u{030A}", isStretchy: false),
        "widehat": Accent(character: "\u{0302}", isStretchy: true),
        "widetilde": Accent(character: "\u{0303}", isStretchy: true),
        "widecheck": Accent(character: "\u{030C}", isStretchy: true),
        "overrightarrow": Accent(character: "→", isStretchy: true),
        "overleftarrow": Accent(character: "←", isStretchy: true),
        "overleftrightarrow": Accent(character: "↔", isStretchy: true),
    ]

    /// Spacing commands in mu (1 em = 18 mu).
    static let spaces: [String: Double] = [
        ",": 3, "thinspace": 3, ":": 4, ">": 4, "medspace": 4, ";": 5, "thickspace": 5,
        "!": -3, "negthinspace": -3, "negmedspace": -4, "negthickspace": -5, "quad": 18,
        "qquad": 36, " ": 6, "space": 6, "nobreakspace": 6, "enspace": 9, "\t": 6, "\n": 6,
    ]

    /// `\not` applied to these relations yields a precomposed negation.
    static let negations: [String: String] = [
        "=": "≠", "∈": "∉", "<": "≮", ">": "≯", "≤": "≰", "≥": "≱", "⊂": "⊄", "⊃": "⊅",
        "⊆": "⊈", "⊇": "⊉", "≡": "≢", "∼": "≁", "≈": "≉", "∋": "∌", "∣": "∤", "∥": "∦",
        "≅": "≇", "≃": "≄", "→": "↛", "←": "↚", "↔": "↮", "⇒": "⇏", "⇐": "⇍", "⇔": "⇎",
        "⊢": "⊬", "⊨": "⊭", "≺": "⊀", "≻": "⊁", "∃": "∄",
    ]

    /// CSS and xcolor names accepted by `\color` and `\textcolor`, as 0xRRGGBB.
    static let colors: [String: UInt32] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
        "yellow": 0xFFFF00, "cyan": 0x00FFFF, "aqua": 0x00FFFF, "magenta": 0xFF00FF,
        "fuchsia": 0xFF00FF, "gray": 0x808080, "grey": 0x808080, "darkgray": 0x404040,
        "lightgray": 0xBFBFBF, "orange": 0xFFA500, "purple": 0x800080, "brown": 0xA52A2A,
        "pink": 0xFFC0CB, "lime": 0x00FF00, "navy": 0x000080, "teal": 0x008080, "olive": 0x808000,
        "maroon": 0x800000, "silver": 0xC0C0C0, "violet": 0xEE82EE, "gold": 0xFFD700,
        "indigo": 0x4B0082, "darkblue": 0x00008B, "darkred": 0x8B0000, "darkgreen": 0x006400,
        "darkorange": 0xFF8C00, "crimson": 0xDC143C, "coral": 0xFF7F50, "salmon": 0xFA8072,
        "turquoise": 0x40E0D0, "skyblue": 0x87CEEB, "royalblue": 0x4169E1, "steelblue": 0x4682B4,
        "forestgreen": 0x228B22, "seagreen": 0x2E8B57, "tomato": 0xFF6347, "orchid": 0xDA70D6,
        "plum": 0xDDA0DD, "tan": 0xD2B48C, "khaki": 0xF0E68C, "lightblue": 0xADD8E6,
        "lightgreen": 0x90EE90,
    ]

    /// Parses a color name or `#rgb` / `#rrggbb` value into 0xRRGGBB; nil when unknown.
    static func colorValue(_ name: String) -> UInt32? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return colors[trimmed.lowercased()] }
        let hex = String(trimmed.dropFirst())
        guard let value = UInt32(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6:
            return value
        case 3:
            let red = (value >> 8) & 0xF, green = (value >> 4) & 0xF, blue = value & 0xF
            return (red * 0x11) << 16 | (green * 0x11) << 8 | blue * 0x11
        default:
            return nil
        }
    }

    /// The atom class of a character typed directly in math mode.
    static func atomClass(of character: Character) -> AgentMathAtomClass {
        switch character {
        case "+", "-", "*", "−", "±", "∓", "×", "÷", "⋅", "∘", "∪", "∩", "∧", "∨", "⊕", "⊗":
            return .bin
        case "=", "<", ">", ":", "≤", "≥", "≠", "≈", "≡", "∼", "≃", "≅", "∝", "∈", "∉", "∋", "⊂",
             "⊃", "⊆", "⊇", "→", "←", "↔", "⇒", "⇐", "⇔", "↦", "⟹", "⟺", "≪", "≫", "⊥", "∥", "∣":
            return .rel
        case ",", ";":
            return .punct
        case "(", "[", "⟨", "⌊", "⌈":
            return .open
        case ")", "]", "!", "?", "⟩", "⌋", "⌉":
            return .close
        default:
            return .ord
        }
    }
}
