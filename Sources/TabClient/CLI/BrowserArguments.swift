import Foundation
import TabProtocol

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

    /// Opens a page in a new pane beside the pane showing `beside`, else in
    /// `project`'s tab, or in a new tab of Home.
    public static func open(url: String?, profile: String?, project: String?, beside: SessionId?,
                            placement: AppPane.Placement) -> BrowserInvocation {
        BrowserInvocation(.open).optional("url", url).optional("profile", profile).optional("project", project)
            .optional("beside", beside?.description).arg("tab", placement == .tab).output(.id)
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

    fileprivate func output(_ output: BrowserOutput) -> Self {
        var copy = self
        copy.output = output
        return copy
    }

    /// Waits up to `--timeout` seconds, else the app's default `wait`, and
    /// gives the app as long.
    fileprivate func waiting(_ arguments: CLIArguments, default wait: TimeInterval) throws -> Self {
        var copy = self
        guard arguments.value("--timeout") != nil else {
            copy.extraTime = wait
            return copy
        }
        let milliseconds = try arguments.timeout(default: wait, maximum: BrowserCommand.maxWait)
        copy = copy.arg("timeoutMs", .int(Int64(milliseconds)))
        copy.extraTime = TimeInterval(milliseconds) / 1000
        return copy
    }
}

/// How the app's reply is printed.
public enum BrowserOutput: Hashable, Sendable {
    /// A new browser's ID, or `{"id":…}` with `--json`.
    case id
    case idJSON
    /// `ok`, once the app has done it.
    case ok
    case json
    /// One tab-separated line per browser.
    case list
    /// Title, URL and text, each on its own line.
    case page
    /// The PNG as base64, ready to decode.
    case screenshot
}

extension CLICommands {
    static let browser = CLIGroup(
        name: "browser", summary: "Drive a browser pane: read, click, type and wait", section: .app,
        commands: [
            page("list", .list, ["[--project PROJECT]"], "The browsers in the app, one line each", words: 0 ... 0,
                 values: ["--project"], json: true) { request, a in
                request.optional("project", a.value("--project")).output(a.json ? .json : .list)
            },
            page("navigate", .navigate, ["BROWSER URL"], "Load a URL", words: 2 ... 2) { request, a in
                request.arg("url", a.word(1)).output(.ok)
            },
            page("read", .read, ["BROWSER"], "Print the title, URL and text of the page", json: true) { request, a in
                request.output(a.json ? .json : .page)
            },
            page("reload", .reload, ["BROWSER"], "Reload the page") { request, _ in request.output(.ok) },
            page("back", .back, ["BROWSER"], "Go back") { request, _ in request.output(.ok) },
            page("forward", .forward, ["BROWSER"], "Go forward") { request, _ in request.output(.ok) },
            page("close", .close, ["BROWSER"], "Close the browser's pane") { request, _ in request.output(.ok) },
            page("screenshot", .screenshot, ["BROWSER"], "Print the page as a base64 PNG") { request, _ in
                var invocation = request.output(.screenshot)
                invocation.extraTime = BrowserCommand.screenshotTime
                return invocation
            },
            page("eval", .evaluate, ["BROWSER JAVASCRIPT"], "Run JavaScript and print its result", words: 2 ... 2) { request, a in
                request.arg("script", a.word(1))
            },
            page("snapshot", .snapshot, ["BROWSER [SELECTOR]"], "Print the interactive elements, each with a selector",
                 words: 1 ... 2) { request, a in
                request.optional("selector", a.optional(1))
            },
            page("find", .find, ["BROWSER role|text|label|placeholder|testid VALUE"], "Print the elements that match",
                 words: 3 ... 3) { request, a in
                request.arg("kind", try a.choice(1, ["role", "text", "label", "placeholder", "testid"]))
                    .arg("value", a.word(2))
            },
            element("click", .click, "Click the element"),
            element("hover", .hover, "Move the pointer over the element"),
            element("scroll-into-view", .scrollIntoView, "Scroll the element into view"),
            page("check", .setChecked, ["BROWSER SELECTOR"], "Check a checkbox", words: 2 ... 2) { request, a in
                request.arg("selector", a.word(1)).arg("checked", true)
            },
            page("uncheck", .setChecked, ["BROWSER SELECTOR"], "Uncheck a checkbox", words: 2 ... 2) { request, a in
                request.arg("selector", a.word(1)).arg("checked", false)
            },
            page("fill", .fill, ["BROWSER SELECTOR TEXT"], "Replace the field's text", words: 3 ... 3) { request, a in
                request.arg("selector", a.word(1)).arg("text", a.word(2))
            },
            page("type", .type, ["BROWSER SELECTOR TEXT [--submit]"], "Type into the field; --submit presses Return",
                 words: 3 ... 3, flags: ["--submit"]) { request, a in
                request.arg("selector", a.word(1)).arg("text", a.word(2)).arg("submit", a.flag("--submit"))
            },
            page("press", .press, ["BROWSER KEY [SELECTOR]"], "Press a key, in the element if given",
                 words: 2 ... 3) { request, a in
                request.arg("key", a.word(1)).optional("selector", a.optional(2))
            },
            page("select", .select, ["BROWSER SELECTOR VALUE"], "Choose an option of a menu", words: 3 ... 3) { request, a in
                request.arg("selector", a.word(1)).arg("value", a.word(2))
            },
            page("is", .is, ["BROWSER visible|hidden|enabled|disabled|checked SELECTOR"], "Print true or false",
                 words: 3 ... 3) { request, a in
                request.arg("property", try a.choice(1, ["visible", "hidden", "enabled", "disabled", "checked"]))
                    .arg("selector", a.word(2))
            },
            element("get-text", .getText, "Print the element's text"),
            element("get-value", .getValue, "Print the field's value"),
            element("get-count", .getCount, "Print how many elements match"),
            page("get-attribute", .getAttribute, ["BROWSER SELECTOR ATTRIBUTE"], "Print an attribute of the element",
                 words: 3 ... 3) { request, a in
                request.arg("selector", a.word(1)).arg("attribute", a.word(2))
            },
            page("get-html", .getHTML, ["BROWSER [SELECTOR]"], "Print the HTML of the page or the element",
                 words: 1 ... 2) { request, a in
                request.optional("selector", a.optional(1))
            },
            page("wait", .wait, ["BROWSER [--selector SELECTOR] [--text TEXT] [--url-contains TEXT] [--function JAVASCRIPT] [--timeout SECONDS]"],
                 "Wait until all the conditions hold; prints true, or false after the timeout",
                 values: ["--selector", "--text", "--url-contains", "--function", "--timeout"]) { request, a in
                try request.optional("selector", a.value("--selector")).optional("text", a.value("--text"))
                    .optional("urlContains", a.value("--url-contains")).optional("function", a.value("--function"))
                    .waiting(a, default: BrowserCommand.defaultWait)
            },
            page("wait-for", .waitFor, ["BROWSER SELECTOR [--timeout SECONDS]"], "Wait until the element shows",
                 words: 2 ... 2, values: ["--timeout"]) { request, a in
                try request.arg("selector", a.word(1)).waiting(a, default: BrowserCommand.defaultWait)
            },
            page("wait-for-navigation", .waitForNavigation, ["BROWSER [--timeout SECONDS]"], "Wait until a page finishes loading",
                 values: ["--timeout"]) { request, a in
                try request.waiting(a, default: BrowserCommand.defaultNavigationWait)
            },
            page("storage get", .storageGet, ["BROWSER KEY [local|session]"], "Print a stored value", words: 2 ... 3) { request, a in
                request.arg("key", a.word(1)).arg("kind", try storage(a, 2))
            },
            page("storage set", .storageSet, ["BROWSER KEY VALUE [local|session]"], "Store a value", words: 3 ... 4) { request, a in
                request.arg("key", a.word(1)).arg("value", a.word(2)).arg("kind", try storage(a, 3)).output(.ok)
            },
            page("storage clear", .storageClear, ["BROWSER [local|session]"], "Delete every stored value", words: 1 ... 2) { request, a in
                request.arg("kind", try storage(a, 1)).output(.ok)
            },
            page("cookies get", .cookiesGet, ["BROWSER [URL]"], "Print the cookies, of a URL if given", words: 1 ... 2) { request, a in
                request.optional("url", a.optional(1))
            },
            page("cookies set", .cookiesSet, ["BROWSER NAME VALUE DOMAIN [--path PATH] [--secure] [--http-only] [--expires UNIX-SECONDS]"],
                 "Set a cookie", words: 4 ... 4, values: ["--path", "--expires"], flags: ["--secure", "--http-only"]) { request, a in
                var invocation = request.arg("name", a.word(1)).arg("value", a.word(2)).arg("domain", a.word(3))
                    .optional("path", a.value("--path")).output(.ok)
                if a.value("--expires") != nil {
                    let expires: UInt64 = try a.number("--expires", default: 0, 0 ... .max)
                    invocation = invocation.arg("expires", expires <= UInt64(Int64.max) ? .int(Int64(expires)) : .uint(expires))
                }
                if a.flag("--secure") { invocation = invocation.arg("secure", true) }
                if a.flag("--http-only") { invocation = invocation.arg("httpOnly", true) }
                return invocation
            },
            page("cookies delete", .cookiesDelete, ["BROWSER NAME [DOMAIN]"], "Delete a cookie", words: 2 ... 3) { request, a in
                request.arg("name", a.word(1)).optional("domain", a.optional(2)).output(.ok)
            },
            page("cookies clear", .cookiesClear, ["BROWSER"], "Delete every cookie") { request, _ in
                request.output(.ok)
            },
        ],
        notes: """
        BROWSER is the ID that tab pane new browser, tab tab new browser and list
        print. Browsers live in the app on this Mac, which must be running.
        Element commands take a CSS selector, such as one snapshot prints, and print
        their result as JSON: false when nothing matches. Waits give up after
        --timeout seconds: 5 by default, 10 for wait-for-navigation, at most 60.
        TAB_CLI_TIMEOUT sets how many seconds the app has to answer (default 10).
        list prints the columns id, title, url, profile and active.
        """)

    /// A browser command; every one but `list` names the browser first.
    private static func page(_ name: String, _ command: BrowserCommand, _ usage: [String], _ summary: String,
                             words: ClosedRange<Int> = 1 ... 1, values: [String] = [], flags: [String] = [],
                             json: Bool = false,
                             build: @escaping @Sendable (BrowserInvocation, CLIArguments) throws -> BrowserInvocation)
        -> CLICommandSpec {
        CLICommandSpec("browser \(name)", usage, summary, words: words, values: values, flags: flags, json: json,
                       place: .app) { a in
            var request = BrowserInvocation(command)
            if command != .list { request = request.arg("tabId", a.word(0)) }
            return .browser(try build(request, a))
        }
    }

    private static func element(_ name: String, _ command: BrowserCommand, _ summary: String) -> CLICommandSpec {
        page(name, command, ["BROWSER SELECTOR"], summary, words: 2 ... 2) { request, a in
            request.arg("selector", a.word(1))
        }
    }

    /// Which web storage a `storage` command uses: `local` unless given.
    private static func storage(_ a: CLIArguments, _ index: Int) throws -> String {
        guard a.optional(index) != nil else { return "local" }
        return try a.choice(index, ["local", "session"])
    }
}

extension BrowserCommand {
    /// How long a screenshot may take.
    static let screenshotTime: TimeInterval = 20
}
