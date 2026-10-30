import Foundation

/// A `tab browser` command as the request it sends to the app.
public struct BrowserInvocation: Hashable, Sendable {
    public var command: BrowserCommand
    public var args: [String: JSONValue]
    public var output: BrowserOutput
    /// How much longer than a quick reply the app may take: what a wait waits
    /// for, or capturing a screenshot.
    public var extraTime: TimeInterval

    public var request: AppRequest { .browser(command: command.rawValue, args: args) }

    init(_ command: BrowserCommand) {
        self.command = command
        args = [:]
        output = .json
        extraTime = 0
    }

    fileprivate func arg(_ key: String, _ value: JSONValue) -> Self {
        var copy = self
        copy.args[key] = value
        return copy
    }

    fileprivate func arg(_ key: String, _ value: String) -> Self { arg(key, .string(value)) }
    fileprivate func arg(_ key: String, _ value: Bool) -> Self { arg(key, .bool(value)) }

    fileprivate func optional(_ key: String, _ value: String?) -> Self {
        value.map { arg(key, $0) } ?? self
    }

    fileprivate func optional(_ key: String, _ value: UInt64?) -> Self {
        value.map { arg(key, $0 <= UInt64(Int64.max) ? .int(Int64($0)) : .uint($0)) } ?? self
    }

    fileprivate func output(_ output: BrowserOutput) -> Self {
        var copy = self
        copy.output = output
        return copy
    }

    /// Gives the app as long as the wait it was asked for.
    fileprivate func waiting(_ defaultWait: TimeInterval) -> Self {
        var copy = self
        if case .int(let milliseconds)? = args["timeoutMs"] {
            copy.extraTime = min(TimeInterval(milliseconds) / 1000, BrowserCommand.maxWait)
        } else if case .uint(let milliseconds)? = args["timeoutMs"] {
            copy.extraTime = min(TimeInterval(milliseconds) / 1000, BrowserCommand.maxWait)
        } else {
            copy.extraTime = defaultWait
        }
        return copy
    }
}

/// How the app's reply is printed.
public enum BrowserOutput: Hashable, Sendable {
    /// A string as it is, such as a new tab's ID.
    case text
    /// `ok`, once the app has done it.
    case ok
    case json
    /// One tab-separated line per tab.
    case tabs
    /// Title, URL and text, each on its own line.
    case page
    /// The PNG as base64, ready to decode.
    case screenshot
}

enum BrowserParser {
    static let screenshotTime: TimeInterval = 20

    static func parse(_ words: [String]) throws -> CLICommand {
        let beforeLiteral = words.prefix { $0 != "--" }
        if words.isEmpty || beforeLiteral.contains("--help") || beforeLiteral.contains("-h") {
            return .help(CLIHelp.browser)
        }
        return .browser(try invocation(words))
    }

    static func command(_ action: String) -> BrowserCommand? {
        switch action {
        case "open": .open
        case "navigate": .navigate
        case "list": .list
        case "read": .read
        case "close": .close
        case "eval", "evaluate": .evaluate
        case "click": .click
        case "type": .type
        case "fill": .fill
        case "press": .press
        case "select": .select
        case "hover": .hover
        case "scroll-into-view": .scrollIntoView
        case "check", "uncheck": .setChecked
        case "is": .is
        case "wait": .wait
        case "wait-for": .waitFor
        case "wait-for-navigation": .waitForNavigation
        case "get-text": .getText
        case "get-html": .getHTML
        case "get-value": .getValue
        case "get-attribute": .getAttribute
        case "get-count": .getCount
        case "find": .find
        case "snapshot": .snapshot
        case "reload": .reload
        case "back": .back
        case "forward": .forward
        case "screenshot": .screenshot
        case "storage get": .storageGet
        case "storage set": .storageSet
        case "storage clear": .storageClear
        case "cookies get": .cookiesGet
        case "cookies set": .cookiesSet
        case "cookies delete": .cookiesDelete
        case "cookies clear": .cookiesClear
        default: nil
        }
    }

    static func invocation(_ words: [String]) throws -> BrowserInvocation {
        let action: String
        let rest: [String]
        if ["storage", "cookies"].contains(words[0]), words.count >= 2 {
            action = "\(words[0]) \(words[1])"
            rest = Array(words.dropFirst(2))
        } else {
            action = words[0]
            rest = Array(words.dropFirst())
        }
        guard let command = command(action) else { throw unknown }
        let request = BrowserInvocation(command)
        func given(_ shape: String, _ count: ClosedRange<Int>, values: [String] = [],
                   flags: [String] = []) throws -> Given {
            try Given(rest, usage: "\(action) \(shape)", count: count, values: values, flags: flags)
        }
        switch action {
        case "open":
            let g = try given("[url] [--split] [--project PROJECT] [--worktree WORKTREE] [--profile PROFILE]", 0 ... 1,
                              values: ["--project", "--worktree", "--profile"], flags: ["--split"])
            return request.optional("url", g.optional(0)).arg("split", g.flag("--split"))
                .optional("project", g.value("--project")).optional("worktree", g.value("--worktree"))
                .optional("profile", g.value("--profile")).output(.text)
        case "list":
            let g = try given("[--project PROJECT] [--worktree WORKTREE] [--json]", 0 ... 0,
                              values: ["--project", "--worktree"], flags: ["--json"])
            return request.optional("project", g.value("--project")).optional("worktree", g.value("--worktree"))
                .output(g.flag("--json") ? .json : .tabs)
        case "read":
            let g = try given("<tab-id> [--json]", 1 ... 1, flags: ["--json"])
            return request.arg("tabId", g.word(0)).output(g.flag("--json") ? .json : .page)
        case "navigate":
            let g = try given("<tab-id> <url>", 2 ... 2)
            return request.arg("tabId", g.word(0)).arg("url", g.word(1)).output(.ok)
        case "close":
            let g = try given("<tab-id>", 1 ... 1)
            return request.arg("tabId", g.word(0)).output(.ok)
        case "reload", "back", "forward", "cookies clear":
            let g = try given("<tab-id>", 1 ... 1)
            return request.arg("tabId", g.word(0))
        case "screenshot":
            let g = try given("<tab-id>", 1 ... 1)
            var invocation = request.arg("tabId", g.word(0)).output(.screenshot)
            invocation.extraTime = screenshotTime
            return invocation
        case "eval", "evaluate":
            let g = try given("<tab-id> <javascript>", 2 ... 2)
            return request.arg("tabId", g.word(0)).arg("script", g.word(1))
        case "click", "hover", "scroll-into-view", "get-text", "get-value", "get-count":
            let g = try given("<tab-id> <selector>", 2 ... 2)
            return request.arg("tabId", g.word(0)).arg("selector", g.word(1))
        case "check", "uncheck":
            let g = try given("<tab-id> <selector>", 2 ... 2)
            return request.arg("tabId", g.word(0)).arg("selector", g.word(1)).arg("checked", action == "check")
        case "fill":
            let g = try given("<tab-id> <selector> <text>", 3 ... 3)
            return request.arg("tabId", g.word(0)).arg("selector", g.word(1)).arg("text", g.word(2))
        case "type":
            let g = try given("<tab-id> <selector> <text> [--submit]", 3 ... 3, flags: ["--submit"])
            return request.arg("tabId", g.word(0)).arg("selector", g.word(1)).arg("text", g.word(2))
                .arg("submit", g.flag("--submit"))
        case "press":
            let g = try given("<tab-id> <key> [selector]", 2 ... 3)
            return request.arg("tabId", g.word(0)).arg("key", g.word(1)).optional("selector", g.optional(2))
        case "select":
            let g = try given("<tab-id> <selector> <value>", 3 ... 3)
            return request.arg("tabId", g.word(0)).arg("selector", g.word(1)).arg("value", g.word(2))
        case "is":
            let g = try given("<tab-id> visible|hidden|enabled|disabled|checked <selector>", 3 ... 3)
            return request.arg("tabId", g.word(0))
                .arg("property", try g.choice(1, ["visible", "hidden", "enabled", "disabled", "checked"]))
                .arg("selector", g.word(2))
        case "get-attribute":
            let g = try given("<tab-id> <selector> <attribute>", 3 ... 3)
            return request.arg("tabId", g.word(0)).arg("selector", g.word(1)).arg("attribute", g.word(2))
        case "get-html", "snapshot":
            let g = try given("<tab-id> [selector]", 1 ... 2)
            return request.arg("tabId", g.word(0)).optional("selector", g.optional(1))
        case "find":
            let g = try given("<tab-id> role|text|label|placeholder|testid <value>", 3 ... 3)
            return request.arg("tabId", g.word(0))
                .arg("kind", try g.choice(1, ["role", "text", "label", "placeholder", "testid"]))
                .arg("value", g.word(2))
        case "wait":
            let g = try given("<tab-id> [--selector SELECTOR] [--text TEXT] [--url-contains TEXT] "
                + "[--function JAVASCRIPT] [--timeout-ms N]", 1 ... 1,
                values: ["--selector", "--text", "--url-contains", "--function", "--timeout-ms"])
            return request.arg("tabId", g.word(0)).optional("selector", g.value("--selector"))
                .optional("text", g.value("--text")).optional("urlContains", g.value("--url-contains"))
                .optional("function", g.value("--function"))
                .optional("timeoutMs", try number(g.value("--timeout-ms"), "--timeout-ms"))
                .waiting(BrowserCommand.defaultWait)
        case "wait-for":
            let g = try given("<tab-id> <selector> [ms]", 2 ... 3)
            return request.arg("tabId", g.word(0)).arg("selector", g.word(1))
                .optional("timeoutMs", try number(g.optional(2), "ms")).waiting(BrowserCommand.defaultWait)
        case "wait-for-navigation":
            let g = try given("<tab-id> [ms] [--timeout-ms N]", 1 ... 2, values: ["--timeout-ms"])
            let timeout: UInt64?
            switch (g.optional(1), g.value("--timeout-ms")) {
            case (.some, .some): throw g.usage
            case (let ms?, nil): timeout = try number(ms, "ms")
            case (nil, let flag): timeout = try number(flag, "--timeout-ms")
            }
            return request.arg("tabId", g.word(0)).optional("timeoutMs", timeout)
                .waiting(BrowserCommand.defaultNavigationWait)
        case "storage get":
            let g = try given("<tab-id> <key> [local|session]", 2 ... 3)
            return request.arg("tabId", g.word(0)).arg("key", g.word(1)).arg("kind", try g.storage(2))
        case "storage set":
            let g = try given("<tab-id> <key> <value> [local|session]", 3 ... 4)
            return request.arg("tabId", g.word(0)).arg("key", g.word(1)).arg("value", g.word(2))
                .arg("kind", try g.storage(3))
        case "storage clear":
            let g = try given("<tab-id> [local|session]", 1 ... 2)
            return request.arg("tabId", g.word(0)).arg("kind", try g.storage(1))
        case "cookies get":
            let g = try given("<tab-id> [url]", 1 ... 2)
            return request.arg("tabId", g.word(0)).optional("url", g.optional(1))
        case "cookies set":
            let g = try given("<tab-id> <name> <value> <domain> [--path PATH] [--secure] [--http-only] "
                + "[--expires UNIX-SECONDS]", 4 ... 4, values: ["--path", "--expires"],
                flags: ["--secure", "--http-only"])
            var invocation = request.arg("tabId", g.word(0)).arg("name", g.word(1)).arg("value", g.word(2))
                .arg("domain", g.word(3)).optional("path", g.value("--path"))
                .optional("expires", try number(g.value("--expires"), "--expires"))
            if g.flag("--secure") { invocation = invocation.arg("secure", true) }
            if g.flag("--http-only") { invocation = invocation.arg("httpOnly", true) }
            return invocation
        case "cookies delete":
            let g = try given("<tab-id> <name> [domain]", 2 ... 3)
            return request.arg("tabId", g.word(0)).arg("name", g.word(1)).optional("domain", g.optional(2))
        default:
            throw unknown
        }
    }

    static func number(_ text: String?, _ name: String) throws -> UInt64? {
        guard let text else { return nil }
        guard let value = UInt64(text) else { throw CLIError("invalid value for \(name)") }
        return value
    }

    static var unknown: CLIError { CLIError("unknown browser command; run tab browser --help") }

    /// The words after the action. Only a word that is exactly one of the
    /// action's options counts as one, so other words starting with a dash
    /// stay positional, and `--` ends options.
    struct Given {
        let shape: String
        var words: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []

        init(_ rest: [String], usage: String, count: ClosedRange<Int>, values known: [String],
             flags knownFlags: [String]) throws {
            shape = usage
            var iterator = rest.makeIterator()
            while let word = iterator.next() {
                if word == "--" {
                    while let literal = iterator.next() { words.append(literal) }
                    break
                }
                if known.contains(word) {
                    guard let value = iterator.next() else { throw CLIError("missing value for \(word)") }
                    guard values.updateValue(value, forKey: word) == nil else {
                        throw CLIError("duplicate option \(word)")
                    }
                } else if knownFlags.contains(word) {
                    guard flags.insert(word).inserted else { throw CLIError("duplicate option \(word)") }
                } else {
                    words.append(word)
                }
            }
            guard count.contains(words.count) else { throw CLIError("usage: tab browser \(usage)") }
        }

        var usage: CLIError { CLIError("usage: tab browser \(shape)") }
        func word(_ index: Int) -> String { words[index] }
        func optional(_ index: Int) -> String? { index < words.count ? words[index] : nil }
        func value(_ name: String) -> String? { values[name] }
        func flag(_ name: String) -> Bool { flags.contains(name) }

        func choice(_ index: Int, _ choices: [String]) throws -> String {
            guard choices.contains(words[index]) else { throw usage }
            return words[index]
        }

        /// Which web storage a `storage` action uses: `local` unless given.
        func storage(_ index: Int) throws -> String {
            guard optional(index) != nil else { return "local" }
            return try choice(index, ["local", "session"])
        }
    }
}
