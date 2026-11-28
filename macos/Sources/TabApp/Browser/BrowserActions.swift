import AppKit
import TabClient
import UniformTypeIdentifiers

/// One `tab browser` action: click, hover, fill, type, press, select,
/// (un)check, upload or scroll. On a pane in a window the pointer and keys
/// are real events, so the page sees trusted input; otherwise scripts stand
/// in and the reply says so. A target in a cross-origin frame (`@f2e5`) is
/// reached in its frame. With `settle`, the reply carries what changed.
@MainActor
struct BrowserActions {
    /// How long `--settle` waits for the page at most.
    static let settleTime: TimeInterval = 5
    /// How long typed keys may take to reach the field.
    static let typingTime: TimeInterval = 2
    /// How much an upload may send to the page, in bytes.
    static let uploadLimit = 50 * 1024 * 1024

    let pane: BrowserPaneController
    let args: JSONValue

    private var settle: Bool { BrowserScripts.flag(args, "settle") }

    func run(_ command: BrowserCommand) async throws -> JSONValue {
        _ = pane.agent.takeOpened()
        pane.agent.acting += 1
        defer { pane.agent.acting -= 1 }
        let choosers = pane.agent.fileChoosers
        let before = settle ? try await snapshotLines() : nil
        var result = BrowserActionsResult()
        let frame = try pane.frame(for: BrowserScripts.optionalString(args, "selector"))
        let action = Action(pane: pane, args: args, frame: frame)
        switch command {
        case .click: guard try await action.click(&result) else { return .bool(false) }
        case .hover: guard try await action.hover(&result) else { return .bool(false) }
        case .fill: guard try await action.fill(&result) else { return .bool(false) }
        case .type: guard try await action.type(&result) else { return .bool(false) }
        case .press: guard try await action.press(&result) else { return .bool(false) }
        case .select: guard try await action.select(&result) else { return .bool(false) }
        case .upload: guard try await action.upload(&result) else { return .bool(false) }
        case .scroll: guard try await action.scroll(&result) else { return .bool(false) }
        default: guard try await action.setChecked(&result) else { return .bool(false) }
        }
        result.dialog = result.dialog ?? pane.agent.dialog
        var diff: String?
        if let before {
            await pane.settle(timeout: Self.settleTime)
            result.dialog = result.dialog ?? pane.agent.dialog
            if result.dialog == nil, let after = try? await snapshotLines() {
                diff = BrowserSnapshotDiff.diff(from: before, to: after)
                pane.agent.lastSnapshot = after
            }
        }
        await waitForWindows()
        let opened = pane.agent.takeOpened()
        if pane.agent.fileChoosers > choosers, pane.agent.unansweredFileChooser, command != .upload {
            result.warning = "the page opened a file chooser; give it files with tab browser upload TARGET FILE"
        }
        guard !result.notes.isEmpty || result.warning != nil || result.dialog != nil || diff != nil || !opened.isEmpty
        else { return .bool(true) }
        var reply: [String: JSONValue] = ["ok": .bool(true)]
        if !result.notes.isEmpty { reply["note"] = .string(result.notes.joined(separator: "; ")) }
        if let warning = result.warning { reply["warning"] = .string(warning) }
        if let dialog = result.dialog { reply["dialog"] = dialog.json }
        if let diff { reply["diff"] = .string(diff) }
        if !opened.isEmpty { reply["opened"] = .array(opened.map(JSONValue.string)) }
        return .object(reply)
    }

    /// Waits briefly for the windows the page asked for to open, so the
    /// reply names them; a round trip to the page first lets input sent
    /// before it reach the page.
    private func waitForWindows() async {
        _ = try? await pane.agentValue("return true;", timeout: 2)
        let deadline = Date().addingTimeInterval(1)
        while pane.agent.windowsHandled < pane.agent.windowsRequested, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The compact snapshot settled actions compare.
    private func snapshotLines() async throws -> [String] {
        try await pane.snapshot("{ interactive: false, compact: true, depth: null, selector: null, urls: false }").lines
    }
}

/// How an action went: notes on how Tab did it, a warning, and a dialog it opened.
@MainActor
private struct BrowserActionsResult {
    var notes: [String] = []
    var warning: String?
    var dialog: PendingDialog?
}

/// An action's steps against its target, in the target's frame.
@MainActor
private struct Action {
    let pane: BrowserPaneController
    let args: JSONValue
    let frame: BrowserAgentState.AgentFrame?

    private var target: String {
        get throws { try BrowserScripts.string(args, "selector") }
    }

    private var targetLiteral: String {
        get throws { BrowserScripts.literal(try target) }
    }

    private func value(_ body: String, timeout: TimeInterval = 10) async throws -> JSONValue {
        try await pane.agentValue(body, timeout: timeout, in: frame)
    }

    /// Scrolls the target into view and checks it can take `action`; nil
    /// when no element matches. The point is in the page's viewport.
    private func prepare(_ action: String) async throws -> (prepared: JSONValue, point: NSPoint?)? {
        let target = try target
        let prepared: JSONValue
        do {
            prepared = try await value("return A.prepare(\(BrowserScripts.literal(target)), \(BrowserScripts.literal(action)));")
        } catch let failure as BrowserScripts.Failure {
            if failure.message.hasPrefix("unknown ref") || failure.message.hasPrefix("stale ref")
                || failure.message.hasPrefix("invalid selector") || failure.message.hasPrefix("the page shows a dialog") {
                throw failure
            }
            throw BrowserScripts.Failure("can't \(action) \(target): \(failure.message)")
        }
        guard prepared != .null else { return nil }
        guard pane.takesNativeInput else { return (prepared, nil) }
        let offset = frame == nil ? (0, 0, nil) : try await pane.offset(of: frame)
        return (prepared, pane.windowPoint(prepared, offset: offset))
    }

    /// Runs `body` in the runtime; a dialog it opens is part of the result.
    private func perform(_ body: String, _ result: inout BrowserActionsResult, arguments: [String: Any] = [:]) async throws
        -> JSONValue {
        switch try await pane.agentRun(body, in: frame, arguments: arguments) {
        case .value(let value): return value
        case .dialog(let dialog):
            result.dialog = dialog
            return .null
        }
    }

    private static let scriptNote = "the pane isn't in a window, so Tab used script events instead of real input"

    // MARK: Pointer

    func click(_ result: inout BrowserActionsResult) async throws -> Bool {
        guard let (_, point) = try await prepare("click") else { return false }
        if let point {
            pane.click(at: point, clickCount: clickCount, button: button)
        } else {
            _ = try await perform("A.scriptClick(A.find(\(try targetLiteral)), \(clickCount), \(button == .right ? 2 : 0)); return true;",
                                  &result)
            result.notes.append(Self.scriptNote)
        }
        return true
    }

    private var clickCount: Int { BrowserScripts.flag(args, "double") ? 2 : 1 }
    private var button: BrowserPaneController.MouseButton { BrowserScripts.flag(args, "right") ? .right : .left }

    func hover(_ result: inout BrowserActionsResult) async throws -> Bool {
        guard let (_, point) = try await prepare("hover") else { return false }
        if let point {
            pane.sendMouse(.mouseMoved, at: point)
        } else {
            _ = try await perform("A.scriptHover(A.find(\(try targetLiteral))); return true;", &result)
            result.notes.append(Self.scriptNote)
        }
        return true
    }

    func setChecked(_ result: inout BrowserActionsResult) async throws -> Bool {
        let wanted = BrowserScripts.flag(args, "checked")
        let state = "const el = A.find(\(try targetLiteral)); return Boolean(el.checked) || el.getAttribute('aria-checked') === 'true';"
        guard let (_, point) = try await prepare("check") else { return false }
        guard try await value(state) != .bool(wanted) else { return true }
        if let point {
            pane.click(at: point)
            if try await waitFor(state, equals: .bool(wanted)) { return true }
            if pane.agent.dialog != nil { return true }
        }
        _ = try await perform("const el = A.find(\(try targetLiteral)); if (Boolean(el.checked) !== \(wanted)) el.click(); return true;", &result)
        result.notes.append(pane.takesNativeInput ? "the click didn't change it, so Tab used a script click" : Self.scriptNote)
        if result.dialog == nil, try await value(state) != .bool(wanted) {
            result.warning = "it is still \(wanted ? "unchecked" : "checked")"
        }
        return true
    }

    func select(_ result: inout BrowserActionsResult) async throws -> Bool {
        guard try await prepare("select") != nil else { return false }
        let value = BrowserScripts.literal(try BrowserScripts.string(args, "value"))
        _ = try await perform("""
        const el = A.find(\(try targetLiteral));
        if (el.localName !== 'select') throw new Error('not_select ' + A.describe(el));
        const wanted = \(value);
        const option = Array.from(el.options).find(item => item.value === wanted)
          || Array.from(el.options).find(item => item.label === wanted || item.textContent.trim() === wanted);
        if (!option) throw new Error('no option ' + JSON.stringify(wanted) + '; the options are '
          + JSON.stringify(Array.from(el.options).slice(0, 20).map(item => item.label || item.value)));
        el.focus();
        A.setValue(el, option.value);
        return true;
        """, &result)
        return true
    }

    // MARK: Files and scrolling

    /// Gives a file field the files: straight to the field when the target is
    /// one (or a label or box holding one), else by clicking the target and
    /// answering the file chooser it opens.
    func upload(_ result: inout BrowserActionsResult) async throws -> Bool {
        let paths: [String]
        switch args["files"] {
        case .array(let values)?: paths = values.compactMap(\.string)
        default: paths = []
        }
        guard !paths.isEmpty else { throw BrowserScripts.Failure("missing argument 'files'") }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        var total = 0
        for url in urls {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else {
                throw BrowserScripts.Failure("no file at \(url.path)")
            }
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        let target = try targetLiteral
        let field = try await value("const el = A.find(\(target)); return el ? A.fileInput(el) !== null : null;")
        if field == .null { return false }
        if field == .bool(true) {
            guard total <= BrowserActions.uploadLimit else {
                throw BrowserScripts.Failure("the files are larger than 50 MB together; upload fewer")
            }
            var files: [[String: Any]] = []
            for url in urls {
                let data: Data
                do { data = try Data(contentsOf: url) } catch {
                    throw BrowserScripts.Failure("can't read \(url.path): \(error.localizedDescription)")
                }
                let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                files.append(["name": url.lastPathComponent, "type": type, "data": data.base64EncodedString(),
                              "lastModified": (modified.timeIntervalSince1970 * 1000).rounded()])
            }
            do {
                _ = try await perform("return A.setFiles(A.find(\(target)), files);", &result, arguments: ["files": files])
            } catch let failure as BrowserScripts.Failure {
                throw BrowserScripts.Failure("can't upload to \(try self.target): \(failure.message)")
            }
            return true
        }
        let choosers = pane.agent.fileChoosers
        pane.agent.pendingFiles = urls
        defer { pane.agent.pendingFiles = nil }
        guard try await click(&result) else { return false }
        let deadline = Date().addingTimeInterval(BrowserActions.typingTime)
        while pane.agent.fileChoosers == choosers, Date() < deadline, result.dialog == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard pane.agent.fileChoosers > choosers else {
            throw BrowserScripts.Failure("clicking \(try self.target) opened no file chooser; target the page's file field, "
                + "such as input[type=file], from get-html or snapshot")
        }
        return true
    }

    func scroll(_ result: inout BrowserActionsResult) async throws -> Bool {
        let x = args["x"]?.number ?? 0, y = args["y"]?.number ?? 0
        let target = BrowserScripts.optionalString(args, "selector").map(BrowserScripts.literal) ?? "null"
        let position = try await perform("return A.scroll(\(target), \(x), \(y));", &result)
        return position != .null
    }

    // MARK: Keyboard

    func fill(_ result: inout BrowserActionsResult) async throws -> Bool {
        guard try await prepare("fill") != nil else { return false }
        let text = try BrowserScripts.string(args, "text")
        let value = try await perform("return A.insertText(A.find(\(try targetLiteral)), \(BrowserScripts.literal(text)), true);", &result)
        if result.dialog == nil, let actual = value.string, actual != text, actual != text.replacingOccurrences(of: "\n", with: "") {
            result.warning = "the field reads \(BrowserScripts.literal(actual)) after filling"
        }
        return true
    }

    func type(_ result: inout BrowserActionsResult) async throws -> Bool {
        guard try await prepare("type") != nil else { return false }
        let text = try BrowserScripts.string(args, "text")
        let element = try targetLiteral
        let focused = try await value("return A.focusField(A.find(\(element)), false);")
        let before = focused["value"]?.string ?? ""
        let keys = text.map(BrowserKey.character)
        let read = "return A.fieldValue(A.find(\(element)));"
        if pane.takesNativeInput, !keys.contains(nil) {
            for key in keys.compactMap({ $0 }) { pane.sendKey(key) }
            if try await waitFor(read, equals: .string(before + text)) {
                // Typed as a user would.
            } else if pane.agent.dialog != nil {
                result.dialog = pane.agent.dialog
                return true
            } else if let actual = try await value(read).string {
                // Keys that didn't land, such as a character the page's keyboard handling dropped: put the text in whole.
                _ = try await perform("return A.insertText(A.find(\(element)), \(BrowserScripts.literal(before + text)), true);", &result)
                result.notes.append(actual == before ? "the page didn't take the keystrokes, so Tab inserted the text"
                    : "the field read \(BrowserScripts.literal(actual)) after the keystrokes, so Tab inserted the text")
                if result.dialog == nil, let final = try await value(read).string, final != before + text {
                    result.warning = "the field reads \(BrowserScripts.literal(final)) after typing"
                }
            }
        } else {
            _ = try await perform("return A.insertText(A.find(\(element)), \(BrowserScripts.literal(text)), false);", &result)
            result.notes.append(pane.takesNativeInput ? "a keyboard can't type all of it, so Tab inserted the text" : Self.scriptNote)
        }
        if BrowserScripts.flag(args, "submit"), result.dialog == nil {
            if pane.takesNativeInput, let enter = BrowserKey.parse("Enter") {
                pane.sendKey(enter)
            } else {
                _ = try await perform("A.submit(A.find(\(element))); return true;", &result)
            }
        }
        return true
    }

    func press(_ result: inout BrowserActionsResult) async throws -> Bool {
        let name = try BrowserScripts.string(args, "key")
        var element = "document.activeElement || document.body"
        if let selector = BrowserScripts.optionalString(args, "selector") {
            guard try await prepare("focus") != nil else { return false }
            element = "A.find(\(BrowserScripts.literal(selector)))"
            _ = try await value("const el = \(element); if (el.focus) el.focus(); return true;")
        }
        if pane.takesNativeInput, let key = BrowserKey.parse(name) {
            pane.sendKey(key)
        } else {
            _ = try await perform("const el = \(element); A.pressKey(el, \(BrowserScripts.literal(name))); return true;", &result)
            result.notes.append(pane.takesNativeInput ? "Tab doesn't know the key \(name), so it sent script key events"
                : Self.scriptNote)
        }
        return true
    }

    /// Polls a runtime check until it answers `expected`, for a short while.
    private func waitFor(_ body: String, equals expected: JSONValue) async throws -> Bool {
        let deadline = Date().addingTimeInterval(BrowserActions.typingTime)
        while Date() < deadline {
            if pane.agent.dialog != nil { return false }
            if (try? await value(body, timeout: BrowserActions.typingTime)) == expected { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
