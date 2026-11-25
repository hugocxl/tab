import AppKit
import TabClient

/// One `tab browser` action: click, hover, fill, type, press, select or
/// (un)check. On a pane in a window the pointer and keys are real events,
/// so the page sees trusted input; otherwise scripts stand in and the reply
/// says so. With `settle`, the reply carries what changed.
@MainActor
struct BrowserActions {
    /// How long `--settle` waits for the page at most.
    static let settleTime: TimeInterval = 5
    /// How long typed keys may take to reach the field.
    static let typingTime: TimeInterval = 2

    let pane: BrowserPaneController
    let args: JSONValue

    private var settle: Bool { BrowserScripts.flag(args, "settle") }

    private struct Result {
        var notes: [String] = []
        var warning: String?
        var dialog: PendingDialog?
    }

    func run(_ command: BrowserCommand) async throws -> JSONValue {
        let before = settle ? try await snapshotLines() : nil
        var result = Result()
        switch command {
        case .click: guard try await click(&result) else { return .bool(false) }
        case .hover: guard try await hover(&result) else { return .bool(false) }
        case .fill: guard try await fill(&result) else { return .bool(false) }
        case .type: guard try await type(&result) else { return .bool(false) }
        case .press: guard try await press(&result) else { return .bool(false) }
        case .select: guard try await select(&result) else { return .bool(false) }
        default: guard try await setChecked(&result) else { return .bool(false) }
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
        guard !result.notes.isEmpty || result.warning != nil || result.dialog != nil || diff != nil else { return .bool(true) }
        var reply: [String: JSONValue] = ["ok": .bool(true)]
        if !result.notes.isEmpty { reply["note"] = .string(result.notes.joined(separator: "; ")) }
        if let warning = result.warning { reply["warning"] = .string(warning) }
        if let dialog = result.dialog { reply["dialog"] = dialog.json }
        if let diff { reply["diff"] = .string(diff) }
        return .object(reply)
    }

    /// The compact snapshot settled actions compare.
    private func snapshotLines() async throws -> [String] {
        let shot = try await pane.agentValue("return A.snapshot({ interactive: false, compact: true, depth: null, selector: null, urls: false });")
        guard case .array(let lines)? = shot["lines"] else { return [] }
        return lines.compactMap(\.string)
    }

    private var target: String {
        get throws { try BrowserScripts.string(args, "selector") }
    }

    private var targetLiteral: String {
        get throws { BrowserScripts.literal(try target) }
    }

    /// Scrolls the target into view and checks it can take `action`; nil when no element matches.
    private func prepare(_ action: String) async throws -> JSONValue? {
        let target = try target
        do {
            let prepared = try await pane.agentValue("return A.prepare(\(BrowserScripts.literal(target)), \(BrowserScripts.literal(action)));")
            return prepared == .null ? nil : prepared
        } catch let failure as BrowserScripts.Failure {
            if failure.message.hasPrefix("unknown ref") || failure.message.hasPrefix("stale ref")
                || failure.message.hasPrefix("invalid selector") || failure.message.hasPrefix("the page shows a dialog") {
                throw failure
            }
            throw BrowserScripts.Failure("can't \(action) \(target): \(failure.message)")
        }
    }

    /// Runs `body` in the runtime; a dialog it opens is part of the result.
    private func perform(_ body: String, _ result: inout Result) async throws -> JSONValue {
        switch try await pane.agentRun(body) {
        case .value(let value): return value
        case .dialog(let dialog):
            result.dialog = dialog
            return .null
        }
    }

    private static let scriptNote = "the pane isn't in a window, so Tab used script events instead of real input"

    // MARK: Pointer

    private func click(_ result: inout Result) async throws -> Bool {
        guard let prepared = try await prepare("click") else { return false }
        if let point = pane.windowPoint(prepared) {
            pane.click(at: point)
        } else {
            _ = try await perform("A.scriptClick(A.find(\(try targetLiteral))); return true;", &result)
            result.notes.append(Self.scriptNote)
        }
        return true
    }

    private func hover(_ result: inout Result) async throws -> Bool {
        guard let prepared = try await prepare("hover") else { return false }
        if let point = pane.windowPoint(prepared) {
            pane.sendMouse(.mouseMoved, at: point)
        } else {
            _ = try await perform("A.scriptHover(A.find(\(try targetLiteral))); return true;", &result)
            result.notes.append(Self.scriptNote)
        }
        return true
    }

    private func setChecked(_ result: inout Result) async throws -> Bool {
        let wanted = BrowserScripts.flag(args, "checked")
        let state = "const el = A.find(\(try targetLiteral)); return Boolean(el.checked) || el.getAttribute('aria-checked') === 'true';"
        guard let prepared = try await prepare("check") else { return false }
        guard try await pane.agentValue(state) != .bool(wanted) else { return true }
        if let point = pane.windowPoint(prepared) {
            pane.click(at: point)
            if try await waitFor(state, equals: .bool(wanted)) { return true }
            if pane.agent.dialog != nil { return true }
        }
        _ = try await perform("const el = A.find(\(try targetLiteral)); if (Boolean(el.checked) !== \(wanted)) el.click(); return true;", &result)
        result.notes.append(pane.takesNativeInput ? "the click didn't change it, so Tab used a script click" : Self.scriptNote)
        if result.dialog == nil, try await pane.agentValue(state) != .bool(wanted) {
            result.warning = "it is still \(wanted ? "unchecked" : "checked")"
        }
        return true
    }

    private func select(_ result: inout Result) async throws -> Bool {
        guard try await prepare("select") != nil else { return false }
        let value = BrowserScripts.literal(try BrowserScripts.string(args, "value"))
        _ = try await perform("""
        const el = A.find(\(try targetLiteral));
        if (el.localName !== 'select') throw new Error('not_select ' + A.describe(el));
        const wanted = \(value);
        const option = Array.from(el.options).find(item => item.value === wanted)
          || Array.from(el.options).find(item => item.label === wanted || item.textContent.trim() === wanted);
        if (!option) throw new Error('no option ' + JSON.stringify(wanted));
        el.focus();
        A.setValue(el, option.value);
        return true;
        """, &result)
        return true
    }

    // MARK: Keyboard

    private func fill(_ result: inout Result) async throws -> Bool {
        guard try await prepare("fill") != nil else { return false }
        let text = try BrowserScripts.string(args, "text")
        let value = try await perform("return A.insertText(A.find(\(try targetLiteral)), \(BrowserScripts.literal(text)), true);", &result)
        if result.dialog == nil, let actual = value.string, actual != text, actual != text.replacingOccurrences(of: "\n", with: "") {
            result.warning = "the field reads \(BrowserScripts.literal(actual)) after filling"
        }
        return true
    }

    private func type(_ result: inout Result) async throws -> Bool {
        guard try await prepare("type") != nil else { return false }
        let text = try BrowserScripts.string(args, "text")
        let element = try targetLiteral
        let focused = try await pane.agentValue("return A.focusField(A.find(\(element)), false);")
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
            } else if try await pane.agentValue(read) == .string(before) {
                _ = try await perform("return A.insertText(A.find(\(element)), \(BrowserScripts.literal(text)), false);", &result)
                result.notes.append("the page didn't take the keystrokes, so Tab inserted the text")
            } else if let actual = try await pane.agentValue(read).string {
                result.warning = "the field reads \(BrowserScripts.literal(actual)) after typing"
            }
        } else {
            _ = try await perform("return A.insertText(A.find(\(element)), \(BrowserScripts.literal(text)), false);", &result)
            result.notes.append(pane.takesNativeInput ? "a US keyboard can't type all of it, so Tab inserted the text"
                : Self.scriptNote)
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

    private func press(_ result: inout Result) async throws -> Bool {
        let name = try BrowserScripts.string(args, "key")
        var element = "document.activeElement || document.body"
        if let selector = BrowserScripts.optionalString(args, "selector") {
            guard try await prepare("focus") != nil else { return false }
            element = "A.find(\(BrowserScripts.literal(selector)))"
            _ = try await pane.agentValue("const el = \(element); if (el.focus) el.focus(); return true;")
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
        let deadline = Date().addingTimeInterval(Self.typingTime)
        while Date() < deadline {
            if pane.agent.dialog != nil { return false }
            if (try? await pane.agentValue(body, timeout: Self.typingTime)) == expected { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
