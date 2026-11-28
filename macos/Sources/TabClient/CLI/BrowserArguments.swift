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
    /// `state load`: the file whose saved state goes to the app as `state`.
    public var stateFile: String?

    public var request: AppRequest { .browser(command: command.rawValue, args: args) }

    init(_ command: BrowserCommand) {
        self.command = command
        args = [:]
        output = .json
        extraTime = 0
    }

    /// The browser named by ID, or `nil` for the caller's.
    public var browser: String? { args["tabId"]?.string }

    /// The compact snapshot actions compare, once the page settles: the
    /// baseline of a batch, or with `delta` what changed since it.
    public static func settledSnapshot(browser: String?, delta: Bool) -> BrowserInvocation {
        var invocation = BrowserInvocation(.snapshot).arg("refs", .bool(true)).arg("compact", .bool(true)).output(.snapshot)
        if let browser { invocation = invocation.arg("tabId", .string(browser)) }
        if delta {
            invocation = invocation.arg("delta", .bool(true)).arg("settle", .bool(true))
            invocation.extraTime = BrowserCommand.settleTime
        }
        return invocation
    }

    /// Opens a page in a new pane on the `edge` of the pane `anchor` names, else
    /// of the pane showing `beside`, else in `project`'s tab, or in a new tab
    /// of Home.
    public static func open(url: String?, profile: String?, project: String?, beside: SessionId?,
                            placement: AppPane.Placement, edge: Direction? = nil,
                            anchor: String? = nil) -> BrowserInvocation {
        BrowserInvocation(.open).optional("url", url).optional("profile", profile).optional("project", project)
            .optional("beside", beside?.description).arg("tab", placement == .tab)
            .optional("edge", edge?.rawValue).optional("anchor", anchor).output(.id)
    }

    public func arg(_ key: String, _ value: JSONValue) -> Self {
        var copy = self
        copy.args[key] = value
        return copy
    }

    fileprivate func arg(_ key: String, _ value: String) -> Self { arg(key, .string(value)) }
    fileprivate func arg(_ key: String, _ value: Bool) -> Self { arg(key, .bool(value)) }

    fileprivate func optional(_ key: String, _ value: String?) -> Self {
        value.map { arg(key, $0) } ?? self
    }

    func output(_ output: BrowserOutput) -> Self {
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

/// `tab browser batch`: steps run one after another against one browser.
public struct BrowserBatch: Hashable, Sendable {
    /// The browser named by ID, or `nil` for the caller's.
    public var browser: String?
    public var steps: [BrowserInvocation]
    /// The text of each step, for messages.
    public var texts: [String]
    /// Wait for the page once the steps are done and print what they changed.
    public var settle: Bool
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
    /// The image written to this absolute path, which is printed.
    case screenshotFile(String)
    /// The snapshot's lines.
    case snapshot
    /// One line per download.
    case downloads
    /// The request with its headers and bodies.
    case request
    /// The saved state written to this absolute path, which is printed.
    case stateFile(String)
    /// `true`/`false`, or an action's diff, with notes and warnings on stderr.
    case action
    /// One line per entry.
    case console
    case errors
    case network
    /// The dialog, or `none`.
    case dialog
}

extension CLICommands {
    static let browser = CLIGroup(
        name: "browser", summary: "Drive a browser pane: read, click, type and wait", section: .app,
        commands: [
            page("list", .list, ["[--project PROJECT]"], "The browsers in the app, one line each", words: 0 ... 0,
                 values: ["--project"], json: true) { request, a in
                request.optional("project", a.value("--project")).output(a.json ? .json : .list)
            },
            page("open", .open, ["BROWSER [URL] [--new] [--profile PROFILE]"],
                 "Load a URL in your browser, or open one beside you; prints its ID",
                 words: 1 ... 2, values: ["--profile"], flags: ["--new"], json: true) { request, a in
                var invocation = request.optional("url", a.optional(1)).optional("profile", a.value("--profile"))
                    .output(a.json ? .idJSON : .id)
                if !a.flag("--new") { invocation = invocation.arg("reuse", true) }
                guard a.flag("--new") || invocation.browser == nil || a.value("--profile") == nil else {
                    throw CLIError("--profile picks the profile of a new browser; add --new or leave out the browser")
                }
                if a.flag("--new") { invocation.args["tabId"] = nil }
                return invocation
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
            page("screenshot", .screenshot,
                 ["BROWSER [SELECTOR] [--output FILE] [--format png|jpeg] [--quality 1-100] [--max-width PIXELS] [--full] [--annotate]"],
                 "Save a picture of the page, or print it as base64",
                 words: 1 ... 2, values: ["--output", "--format", "--quality", "--max-width"],
                 flags: ["--full", "--annotate"]) { request, a in
                if let word = a.optional(1), [".png", ".jpg", ".jpeg"].contains(where: { word.lowercased().hasSuffix($0) }) {
                    throw CLIError("to save the screenshot, pass --output \(word)")
                }
                var invocation = request.optional("selector", a.optional(1))
                if let format = a.value("--format") {
                    guard ["png", "jpeg", "jpg"].contains(format) else { throw a.usage }
                    invocation = invocation.arg("format", format == "jpg" ? "jpeg" : format)
                }
                if a.value("--quality") != nil {
                    invocation = invocation.arg("quality", .int(Int64(try a.number("--quality", default: 80, 1 ... 100) as Int)))
                }
                if a.value("--max-width") != nil {
                    invocation = invocation.arg("maxWidth", .int(Int64(try a.number("--max-width", default: 0, 16 ... 20_000) as Int)))
                }
                if a.flag("--full") { invocation = invocation.arg("full", true) }
                if a.flag("--annotate") { invocation = invocation.arg("annotate", true) }
                if let output = a.value("--output") {
                    let path = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL.path
                    invocation = invocation.output(.screenshotFile(path))
                } else {
                    invocation = invocation.output(.screenshot)
                }
                invocation.extraTime = BrowserCommand.screenshotTime
                return invocation
            },
            page("eval", .evaluate, ["BROWSER JAVASCRIPT"], "Run JavaScript and print its result", words: 2 ... 2) { request, a in
                request.arg("script", a.word(1))
            },
            page("snapshot", .snapshot,
                 ["BROWSER [-i] [-c] [-d DEPTH] [-s SELECTOR] [-u] [--delta] [--settle] [--json]"],
                 "Print the page's elements, each with a ref such as @e1",
                 words: 1 ... 2, values: ["-d", "--depth", "-s", "--selector"],
                 flags: ["-i", "--interactive", "-c", "--compact", "-u", "--urls", "--delta", "--settle"], json: true) { request, a in
                var invocation = request.arg("refs", true)
                    .optional("selector", try a.either("-s", "--selector") ?? a.optional(1))
                if a.flag("-i") || a.flag("--interactive") { invocation = invocation.arg("interactive", true) }
                if a.flag("-c") || a.flag("--compact") { invocation = invocation.arg("compact", true) }
                if a.flag("-u") || a.flag("--urls") { invocation = invocation.arg("urls", true) }
                if a.flag("--delta") { invocation = invocation.arg("delta", true) }
                if a.flag("--settle") {
                    invocation = invocation.arg("settle", true)
                    invocation.extraTime += BrowserCommand.settleTime
                }
                if let depth = try a.either("-d", "--depth") {
                    guard let value = Int(depth), (0 ... 1000).contains(value) else {
                        throw CLIError("--depth must be a whole number from 0 to 1000")
                    }
                    invocation = invocation.arg("depth", .int(Int64(value)))
                }
                return invocation.output(a.json ? .json : .snapshot)
            },
            page("find", .find, ["BROWSER role|text|label|placeholder|testid VALUE"], "Print the elements that match",
                 words: 3 ... 3) { request, a in
                request.arg("kind", try a.choice(1, ["role", "text", "label", "placeholder", "testid"]))
                    .arg("value", a.word(2))
            },
            action("click", .click, ["BROWSER TARGET [--double] [--right]"], "Click the element, twice or with the right button",
                   words: 2 ... 2, flags: ["--double", "--right"]) { request, a in
                var invocation = request.arg("selector", a.word(1))
                if a.flag("--double") { invocation = invocation.arg("double", true) }
                if a.flag("--right") { invocation = invocation.arg("right", true) }
                return invocation
            },
            action("hover", .hover, ["BROWSER TARGET"], "Move the pointer over the element", words: 2 ... 2) { request, a in
                request.arg("selector", a.word(1))
            },
            element("scroll-into-view", .scrollIntoView, "Scroll the element into view"),
            action("check", .setChecked, ["BROWSER TARGET"], "Check a checkbox", words: 2 ... 2) { request, a in
                request.arg("selector", a.word(1)).arg("checked", true)
            },
            action("uncheck", .setChecked, ["BROWSER TARGET"], "Uncheck a checkbox", words: 2 ... 2) { request, a in
                request.arg("selector", a.word(1)).arg("checked", false)
            },
            action("fill", .fill, ["BROWSER TARGET TEXT"], "Replace the field's text", words: 3 ... 3) { request, a in
                request.arg("selector", a.word(1)).arg("text", a.word(2))
            },
            action("type", .type, ["BROWSER TARGET TEXT [--submit]"], "Type at the end of the field; --submit presses Return",
                   words: 3 ... 3, flags: ["--submit"]) { request, a in
                request.arg("selector", a.word(1)).arg("text", a.word(2)).arg("submit", a.flag("--submit"))
            },
            action("press", .press, ["BROWSER KEY [TARGET]"], "Press a key such as Enter or Meta+a, in the element if given",
                   words: 2 ... 3) { request, a in
                request.arg("key", a.word(1)).optional("selector", a.optional(2))
            },
            action("select", .select, ["BROWSER TARGET VALUE"], "Choose an option of a menu by value or label",
                   words: 3 ... 3) { request, a in
                request.arg("selector", a.word(1)).arg("value", a.word(2))
            },
            action("upload", .upload, ["BROWSER TARGET FILE..."],
                   "Give a file field files, or the file chooser the target opens", words: 3 ... 52) { request, a in
                let files = a.words.dropFirst(2).map {
                    JSONValue.string(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path)
                }
                return request.arg("selector", a.word(1)).arg("files", .array(Array(files)))
            },
            action("scroll", .scroll, ["BROWSER up|down|left|right [PIXELS] [--selector TARGET]"],
                   "Scroll the page, or an element that scrolls; 500 pixels unless given",
                   words: 2 ... 3, values: ["--selector"]) { request, a in
                let direction = try a.choice(1, ["up", "down", "left", "right"])
                var distance = 500
                if let text = a.optional(2) {
                    guard let value = Int(text), (1 ... 100_000).contains(value) else {
                        throw CLIError("PIXELS must be a whole number from 1 to 100000")
                    }
                    distance = value
                }
                let x = direction == "left" ? -distance : direction == "right" ? distance : 0
                let y = direction == "up" ? -distance : direction == "down" ? distance : 0
                return request.arg("x", .int(Int64(x))).arg("y", .int(Int64(y))).optional("selector", a.value("--selector"))
            },
            CLICommandSpec("browser batch", ["[BROWSER] STEP... [--settle]"],
                           "Run steps such as \"click @e3\" in turn; --settle prints what they changed",
                           words: 1 ... 100, flags: ["--settle"], place: .app) { a in
                var words = a.words
                let browser = words.count > 1 && isBrowserId(words[0]) ? words.removeFirst() : nil
                let steps = try words.map { text in
                    var step = try batchStep(text)
                    if let browser, step.browser == nil { step = step.arg("tabId", .string(browser)) }
                    return step
                }
                return .browserBatch(BrowserBatch(browser: browser, steps: steps, texts: words, settle: a.flag("--settle")))
            },
            page("dialog", .dialog, ["BROWSER [status|accept|dismiss] [TEXT]"],
                 "Print the page's open dialog, or answer it; TEXT answers a prompt", words: 1 ... 3, json: true) { request, a in
                let action = a.optional(1) == nil ? "status" : try a.choice(1, ["status", "accept", "dismiss"])
                guard a.optional(2) == nil || action == "accept" else { throw a.usage }
                return request.arg("action", action).optional("text", a.optional(2)).output(a.json ? .json : .dialog)
            },
            page("console", .console, ["BROWSER [--clear]"], "Print the page's console messages", flags: ["--clear"],
                 json: true) { request, a in
                (a.flag("--clear") ? request.arg("clear", true) : request).output(a.json ? .json : .console)
            },
            page("errors", .errors, ["BROWSER [--clear]"], "Print the page's uncaught errors", flags: ["--clear"],
                 json: true) { request, a in
                (a.flag("--clear") ? request.arg("clear", true) : request).output(a.json ? .json : .errors)
            },
            page("network", .network,
                 ["BROWSER [--filter TEXT] [--method METHOD] [--status 404|4xx] [--type fetch|xhr] [--clear]"],
                 "Print the page's fetch and XHR requests, numbered", values: ["--filter", "--method", "--status", "--type"],
                 flags: ["--clear"], json: true) { request, a in
                if let type = a.value("--type"), !["fetch", "xhr"].contains(type) { throw a.usage }
                if let status = a.value("--status"), Int(status) == nil,
                   !(status.count == 3 && status.lowercased().hasSuffix("xx") && status.first?.isNumber == true) {
                    throw CLIError("--status takes a status such as 404, or a class such as 4xx")
                }
                return (a.flag("--clear") ? request.arg("clear", true) : request).optional("filter", a.value("--filter"))
                    .optional("method", a.value("--method")).optional("status", a.value("--status"))
                    .optional("type", a.value("--type")).output(a.json ? .json : .network)
            },
            page("network request", .network, ["BROWSER NUMBER"], "Print a request with its headers and bodies",
                 words: 2 ... 2, json: true) { request, a in
                guard let number = Int(a.word(1)), number > 0 else { throw CLIError("NUMBER is the number network prints") }
                return request.arg("id", .int(Int64(number))).output(a.json ? .json : .request)
            },
            page("downloads", .downloads, ["BROWSER [--clear]"], "Print the page's downloads and where they went",
                 flags: ["--clear"], json: true) { request, a in
                (a.flag("--clear") ? request.arg("clear", true) : request).output(a.json ? .json : .downloads)
            },
            page("wait-for-download", .waitForDownload, ["BROWSER [--timeout SECONDS]"],
                 "Wait until a download finishes; prints it, or null after the timeout", values: ["--timeout"]) { request, a in
                try request.waiting(a, default: BrowserCommand.defaultNavigationWait)
            },
            page("state save", .stateSave, ["BROWSER FILE"],
                 "Save the profile's cookies and the page's local storage to a file", words: 2 ... 2) { request, a in
                request.output(.stateFile(URL(fileURLWithPath: (a.word(1) as NSString).expandingTildeInPath).standardizedFileURL.path))
            },
            page("state load", .stateLoad, ["BROWSER FILE"],
                 "Load cookies and local storage a state save wrote", words: 2 ... 2) { request, a in
                var invocation = request
                invocation.stateFile = URL(fileURLWithPath: (a.word(1) as NSString).expandingTildeInPath).standardizedFileURL.path
                return invocation
            },
            page("set viewport", .setViewport, ["BROWSER WIDTH HEIGHT", "BROWSER reset"],
                 "Give the page a fixed size in CSS pixels", words: 2 ... 3) { request, a in
                if a.words.count == 2 {
                    guard a.word(1) == "reset" else { throw a.usage }
                    return request.arg("reset", true).output(.ok)
                }
                guard let width = Int(a.word(1)), let height = Int(a.word(2)),
                      (100 ... 10_000).contains(width), (100 ... 10_000).contains(height)
                else { throw CLIError("the viewport must be 100 to 10000 pixels wide and high") }
                return request.arg("width", .int(Int64(width))).arg("height", .int(Int64(height))).output(.ok)
            },
            page("set device", .setDevice, ["BROWSER iphone|ipad|pixel|desktop"],
                 "Size the page and set the user agent of a device", words: 2 ... 2) { request, a in
                request.arg("device", try a.choice(1, ["iphone", "ipad", "pixel", "desktop"]))
            },
            page("set media", .setMedia, ["BROWSER dark|light|auto"], "Set the color scheme the page sees",
                 words: 2 ... 2) { request, a in
                request.arg("media", try a.choice(1, ["dark", "light", "auto"])).output(.ok)
            },
            page("is", .is, ["BROWSER visible|hidden|enabled|disabled|checked SELECTOR"], "Print true or false",
                 words: 3 ... 3) { request, a in
                request.arg("property", try a.choice(1, ["visible", "hidden", "enabled", "disabled", "checked"]))
                    .arg("selector", a.word(2))
            },
            element("get-text", .getText, "Print the element's text"),
            element("get-value", .getValue, "Print the field's value"),
            element("get-count", .getCount, "Print how many elements match"),
            element("get-box", .getBox, "Print the element's position and size in the page, in CSS pixels"),
            page("get-attribute", .getAttribute, ["BROWSER SELECTOR ATTRIBUTE"], "Print an attribute of the element",
                 words: 3 ... 3) { request, a in
                request.arg("selector", a.word(1)).arg("attribute", a.word(2))
            },
            page("get-html", .getHTML, ["BROWSER [SELECTOR]"], "Print the HTML of the page or the element",
                 words: 1 ... 2) { request, a in
                request.optional("selector", a.optional(1))
            },
            page("wait", .wait,
                 ["BROWSER [--selector TARGET] [--text TEXT] [--url-contains TEXT] [--function JAVASCRIPT] [--load load|networkidle] [--timeout SECONDS]"],
                 "Wait until all the conditions hold; prints true, or false after the timeout",
                 values: ["--selector", "--text", "--url-contains", "--function", "--load", "--timeout"]) { request, a in
                if let load = a.value("--load"), !["load", "networkidle"].contains(load) { throw a.usage }
                return try request.optional("selector", a.value("--selector")).optional("text", a.value("--text"))
                    .optional("urlContains", a.value("--url-contains")).optional("function", a.value("--function"))
                    .optional("load", a.value("--load")).waiting(a, default: BrowserCommand.defaultWait)
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
        BROWSER is a browser's ID, as open, list, tab pane new browser and tab tab
        new browser print it. Leave it out to drive your browser: the one you
        last named or opened, else the only one in your tab, else the only one
        open. Browsers live in the app on this Mac, which must be running.
        open URL loads the URL in your browser, or opens one beside you when you
        have none; --new always opens another.
        TARGET and SELECTOR take a ref that snapshot printed, such as @e3, or a CSS
        selector, which also finds elements in shadow roots and same-origin
        frames. Elements of cross-origin frames get refs such as @f2e5. Refs last
        until their element leaves the page; a ref from an earlier page fails.
        Commands print their result as JSON: false when no element matches a CSS
        selector.
        snapshot -i lists only interactive elements, -c leaves out empty
        structure, -d stops at a depth, -s starts at the elements a selector
        matches, -u adds link URLs, --delta prints only what changed since the
        last snapshot (- gone, + new), and --settle waits for the page first.
        click, hover, type and press send real mouse and key events when the
        browser is in a window, and script events otherwise (the note on stderr
        says so). Actions fail, saying why, when the element is covered,
        disabled or not editable. --settle waits for the page to settle and
        prints what changed. A page that opens a window opens a browser beside
        it; the action prints its ID on stderr.
        upload gives a file field files without a file chooser; a button that
        opens a chooser gets them when clicked.
        A page's alert, confirm or prompt waits for dialog accept or dismiss.
        console, errors and network show what the page logged and fetched since an
        agent first drove the browser; reload to see a page load's own. network
        request N shows request N's headers and bodies.
        Waits give up after --timeout seconds: 5 by default, 10 for
        wait-for-navigation and wait-for-download, at most 60. wait --load
        networkidle waits until no fetch or XHR has run for half a second.
        TAB_CLI_TIMEOUT sets how many seconds the app has to answer (default 10).
        state save writes the profile's cookies and the page's local storage,
        tokens included, so keep the file private; state load signs another
        browser in with it.
        batch runs steps such as "click @e3" in turn and stops at the first that
        fails; --settle prints what they changed once the page settles.
        list prints the columns id, title, url, profile and active.
        """)

    /// An action, which can wait for the page to settle with `--settle`.
    private static func action(_ name: String, _ command: BrowserCommand, _ usage: [String], _ summary: String,
                               words: ClosedRange<Int>, values: [String] = [], flags: [String] = [],
                               build: @escaping @Sendable (BrowserInvocation, CLIArguments) throws -> BrowserInvocation)
        -> CLICommandSpec {
        page(name, command, usage.map { $0 + " [--settle]" }, summary, words: words, values: values,
             flags: flags + ["--settle"]) { request, a in
            var invocation = try build(request, a).output(.action)
            if a.flag("--settle") {
                invocation = invocation.arg("settle", true)
                invocation.extraTime += BrowserCommand.settleTime
            }
            return invocation
        }
    }

    /// A browser command. Every one but `list` may name the browser by its
    /// ID first; without one it drives the caller's. `build` sees the
    /// browser, or an empty word, as word 0.
    private static func page(_ name: String, _ command: BrowserCommand, _ usage: [String], _ summary: String,
                             words: ClosedRange<Int> = 1 ... 1, values: [String] = [], flags: [String] = [],
                             json: Bool = false,
                             build: @escaping @Sendable (BrowserInvocation, CLIArguments) throws -> BrowserInvocation)
        -> CLICommandSpec {
        guard command != .list else {
            return CLICommandSpec("browser \(name)", usage, summary, words: words, values: values, flags: flags, json: json,
                                  place: .app) { a in .browser(try build(BrowserInvocation(command), a)) }
        }
        let shown = usage.map { $0.hasPrefix("BROWSER") ? "[BROWSER]" + $0.dropFirst("BROWSER".count) : $0 }
        return CLICommandSpec("browser \(name)", shown, summary, words: max(words.lowerBound - 1, 0) ... words.upperBound,
                              values: values, flags: flags, json: json, place: .app) { given in
            var a = given
            // The browser comes first when every word is given, or when the first is an ID.
            let named = a.words.count == words.upperBound
                || a.words.count >= words.lowerBound && a.words.first.map(isBrowserId) == true
            if !named { a.words.insert("", at: 0) }
            guard words.contains(a.words.count) else { throw a.usage }
            var request = BrowserInvocation(command)
            if !a.word(0).isEmpty { request = request.arg("tabId", a.word(0)) }
            return .browser(try build(request, a))
        }
    }

    /// One `batch` step, such as `click @e3` or `fill @e2 "ada@example.com"`,
    /// as the browser command it names.
    static func batchStep(_ text: String) throws -> BrowserInvocation {
        let words = try SimulatorSteps.words(text)
        guard !words.isEmpty else { throw CLIError("a batch step is empty") }
        let (spec, count) = browser.command(for: words)
        guard let spec, spec.name != "browser batch", spec.name != "browser list" else {
            throw CLIError("unknown step \"\(text)\"; a step is a tab browser command, such as \"click @e3\"")
        }
        let arguments: CLIArguments
        do {
            arguments = try CLIArguments(Array(words.dropFirst(count)), spec: spec)
        } catch let error as CLIError {
            throw CLIError("in step \"\(text)\": \(error.message)")
        }
        guard case .browser(let invocation) = try spec.build(arguments) else {
            throw CLIError("unknown step \"\(text)\"")
        }
        return invocation
    }

    /// Whether a word is a browser's ID (a pane's or tab's) rather than a
    /// command's first argument.
    static func isBrowserId(_ word: String) -> Bool { UUID(uuidString: word) != nil }

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
    /// How long an action may wait for the page to settle, and type.
    static let settleTime: TimeInterval = 8
}

extension CLIArguments {
    /// The value of an option that has a short and a long name.
    func either(_ short: String, _ long: String) throws -> String? {
        if value(short) != nil, value(long) != nil {
            throw CLIError("\(short) and \(long) are the same option; give it once")
        }
        return value(short) ?? value(long)
    }
}
