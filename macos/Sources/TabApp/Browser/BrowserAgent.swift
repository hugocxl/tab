import AppKit
import ImageIO
import TabClient
import UniformTypeIdentifiers
import WebKit

/// What agents driving a browser pane leave behind on it: the next ref to
/// hand out, the last snapshot, captured logs and a dialog waiting for an
/// answer. Panes nobody automates never fill it.
@MainActor
final class BrowserAgentState {
    static let consoleLimit = 500
    static let errorLimit = 200
    static let requestLimit = 500

    /// The first ref number a newly installed runtime hands out.
    var nextRef = 1
    /// The lines of the last snapshot, for `--delta`.
    var lastSnapshot: [String]?
    /// Whether an agent has driven the pane, so its page logs are captured
    /// and dialogs wait for `tab browser dialog` when nobody can see them.
    private(set) var driven = false
    private(set) var console: [ConsoleEntry] = []
    private(set) var errors: [ErrorEntry] = []
    private(set) var requests: [RequestEntry] = []
    private var requestIndex: [String: Int] = [:]
    private(set) var dialog: PendingDialog?
    private var dialogWatchers: [Int: (PendingDialog) -> Void] = [:]
    private var watcherId = 0
    private let started = Date()

    struct ConsoleEntry: Equatable {
        var time: TimeInterval
        var level: String
        var text: String
        var url: String
    }

    struct ErrorEntry: Equatable {
        var time: TimeInterval
        var text: String
        var source: String
        var line: Int
        var column: Int
        var stack: String
    }

    struct RequestEntry: Equatable {
        var id: String
        var time: TimeInterval
        var method: String
        var url: String
        var type: String
        var status: Int?
        var error: String?
        var milliseconds: Int?
        var pending: Bool { status == nil && error == nil }
    }

    /// Marks the pane as agent-driven; returns whether it already was.
    @discardableResult
    func drive() -> Bool {
        defer { driven = true }
        return driven
    }

    var pendingRequests: Int { requests.reduce(0) { $0 + ($1.pending ? 1 : 0) } }

    /// A new page: its requests can't finish anymore.
    func navigationStarted() {
        for index in requests.indices where requests[index].pending {
            requests[index].error = "cancelled by navigation"
        }
    }

    // MARK: Logs

    func receive(_ body: Any) {
        guard let message = body as? [String: Any], let kind = message["kind"] as? String else { return }
        let now = Date().timeIntervalSince(started)
        func text(_ key: String) -> String { (message[key] as? String) ?? "" }
        func number(_ key: String) -> Int? { (message[key] as? NSNumber)?.intValue }
        switch kind {
        case "console":
            append(&console, ConsoleEntry(time: now, level: text("level"), text: text("text"), url: text("url")),
                   limit: Self.consoleLimit)
        case "error":
            append(&errors, ErrorEntry(time: now, text: text("text"), source: text("source"), line: number("line") ?? 0,
                                       column: number("column") ?? 0, stack: text("stack")),
                   limit: Self.errorLimit)
        case "request":
            let id = text("id")
            if text("phase") == "start" {
                append(&requests, RequestEntry(id: id, time: now, method: text("method"), url: text("url"), type: text("type")),
                       limit: Self.requestLimit)
                requestIndex = Dictionary(requests.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { $1 })
            } else if let index = requestIndex[id], requests.indices.contains(index), requests[index].id == id {
                requests[index].status = number("status")
                requests[index].error = message["error"] as? String
                requests[index].milliseconds = number("ms")
            }
        default:
            break
        }
    }

    private func append<T>(_ list: inout [T], _ entry: T, limit: Int) {
        list.append(entry)
        if list.count > limit { list.removeFirst(list.count - limit) }
    }

    func clearConsole() { console.removeAll() }
    func clearErrors() { errors.removeAll() }
    func clearRequests() {
        requests.removeAll { !$0.pending }
        requestIndex = Dictionary(requests.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { $1 })
    }

    // MARK: Dialogs

    func open(_ dialog: PendingDialog) {
        self.dialog?.answer(accept: false, text: nil)
        self.dialog = dialog
        for watcher in dialogWatchers.values { watcher(dialog) }
    }

    func closed(_ dialog: PendingDialog) {
        if self.dialog === dialog { self.dialog = nil }
    }

    /// Calls `watcher` when a dialog opens until the returned token is passed to `unwatch`.
    func watchDialogs(_ watcher: @escaping (PendingDialog) -> Void) -> Int {
        watcherId += 1
        dialogWatchers[watcherId] = watcher
        return watcherId
    }

    func unwatch(_ token: Int) {
        dialogWatchers[token] = nil
    }
}

/// A JavaScript `alert`, `confirm` or `prompt` waiting for an answer, from
/// the user on its sheet or from `tab browser dialog`.
@MainActor
final class PendingDialog {
    enum Kind: String { case alert, confirm, prompt }

    let kind: Kind
    let message: String
    let defaultText: String?
    let origin: String
    /// The sheet showing it, when the pane is on screen.
    var alert: NSAlert?
    var field: NSTextField?
    private var finish: ((Bool, String?) -> Void)?

    init(kind: Kind, message: String, defaultText: String?, origin: String, finish: @escaping (Bool, String?) -> Void) {
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
        self.origin = origin
        self.finish = finish
    }

    var summary: String { "\(kind.rawValue) \(BrowserScripts.literal(message))" }

    var json: JSONValue {
        var object: [String: JSONValue] = ["type": .string(kind.rawValue), "message": .string(message),
                                           "origin": .string(origin)]
        if let defaultText { object["defaultText"] = .string(defaultText) }
        return .object(object)
    }

    /// Answers once: a sheet on screen ends as if its button was clicked.
    func answer(accept: Bool, text: String?) {
        if let alert, let sheetParent = alert.window.sheetParent {
            if let text { field?.stringValue = text }
            sheetParent.endSheet(alert.window, returnCode: accept ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            return
        }
        resolve(accept: accept, text: accept ? (text ?? field?.stringValue ?? defaultText ?? "") : nil)
    }

    func resolve(accept: Bool, text: String?) {
        guard let finish else { return }
        self.finish = nil
        finish(accept, text)
    }
}

/// Receives log messages without the web view's content controller keeping
/// the pane alive.
final class BrowserLogHandler: NSObject, WKScriptMessageHandler {
    weak var pane: BrowserPaneController?

    init(pane: BrowserPaneController) {
        self.pane = pane
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            pane?.agent.receive(message.body)
        }
    }
}

// MARK: - Keys

/// A key as `tab browser press` names it, such as `Enter`, `a` or
/// `Meta+a`, turned into what a keyboard would send.
struct BrowserKey: Equatable {
    var keyCode: UInt16
    var characters: String
    var charactersIgnoringModifiers: String
    var modifiers: NSEvent.ModifierFlags

    static func == (lhs: BrowserKey, rhs: BrowserKey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.characters == rhs.characters
            && lhs.charactersIgnoringModifiers == rhs.charactersIgnoringModifiers && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    private static let named: [String: (UInt16, Int)] = [
        "enter": (36, 0x0D), "return": (36, 0x0D), "tab": (48, 0x09), "space": (49, 0x20), "escape": (53, 0x1B),
        "esc": (53, 0x1B), "backspace": (51, 0x7F), "delete": (117, NSDeleteFunctionKey),
        "arrowup": (126, NSUpArrowFunctionKey), "up": (126, NSUpArrowFunctionKey),
        "arrowdown": (125, NSDownArrowFunctionKey), "down": (125, NSDownArrowFunctionKey),
        "arrowleft": (123, NSLeftArrowFunctionKey), "left": (123, NSLeftArrowFunctionKey),
        "arrowright": (124, NSRightArrowFunctionKey), "right": (124, NSRightArrowFunctionKey),
        "home": (115, NSHomeFunctionKey), "end": (119, NSEndFunctionKey),
        "pageup": (116, NSPageUpFunctionKey), "pagedown": (121, NSPageDownFunctionKey),
        "f1": (122, NSF1FunctionKey), "f2": (120, NSF2FunctionKey), "f3": (99, NSF3FunctionKey),
        "f4": (118, NSF4FunctionKey), "f5": (96, NSF5FunctionKey), "f6": (97, NSF6FunctionKey),
        "f7": (98, NSF7FunctionKey), "f8": (100, NSF8FunctionKey), "f9": (101, NSF9FunctionKey),
        "f10": (109, NSF10FunctionKey), "f11": (103, NSF11FunctionKey), "f12": (111, NSF12FunctionKey),
    ]

    /// US-layout key codes and whether Shift makes the character.
    private static let layout: [Character: (UInt16, Bool)] = {
        var table: [Character: (UInt16, Bool)] = [:]
        let keys: [(String, String, UInt16)] = [
            ("a", "A", 0), ("s", "S", 1), ("d", "D", 2), ("f", "F", 3), ("h", "H", 4), ("g", "G", 5), ("z", "Z", 6),
            ("x", "X", 7), ("c", "C", 8), ("v", "V", 9), ("b", "B", 11), ("q", "Q", 12), ("w", "W", 13), ("e", "E", 14),
            ("r", "R", 15), ("y", "Y", 16), ("t", "T", 17), ("1", "!", 18), ("2", "@", 19), ("3", "#", 20),
            ("4", "$", 21), ("6", "^", 22), ("5", "%", 23), ("=", "+", 24), ("9", "(", 25), ("7", "&", 26),
            ("-", "_", 27), ("8", "*", 28), ("0", ")", 29), ("]", "}", 30), ("o", "O", 31), ("u", "U", 32),
            ("[", "{", 33), ("i", "I", 34), ("p", "P", 35), ("l", "L", 37), ("j", "J", 38), ("'", "\"", 39),
            ("k", "K", 40), (";", ":", 41), ("\\", "|", 42), (",", "<", 43), ("/", "?", 44), ("n", "N", 45),
            ("m", "M", 46), (".", ">", 47), ("`", "~", 50),
        ]
        for (plain, shifted, code) in keys {
            table[Character(plain)] = (code, false)
            table[Character(shifted)] = (code, true)
        }
        table[" "] = (49, false)
        return table
    }()

    /// The key for one typed character, or nil when a US keyboard has none.
    static func character(_ character: Character) -> BrowserKey? {
        switch character {
        case "\n", "\r": return BrowserKey(keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r", modifiers: [])
        case "\t": return BrowserKey(keyCode: 48, characters: "\t", charactersIgnoringModifiers: "\t", modifiers: [])
        default:
            guard let (code, shift) = layout[character] else { return nil }
            let text = String(character)
            return BrowserKey(keyCode: code, characters: text, charactersIgnoringModifiers: text,
                              modifiers: shift ? .shift : [])
        }
    }

    /// Parses `Enter`, `a`, `Shift+Tab`, `Meta+a`, `Control+ArrowLeft` and the like.
    static func parse(_ name: String) -> BrowserKey? {
        var parts = name.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if name.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part.lowercased() {
            case "shift": modifiers.insert(.shift)
            case "control", "ctrl": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "meta", "cmd", "command", "super": modifiers.insert(.command)
            default: return nil
            }
        }
        if last.count > 1, let (code, scalar) = named[last.lowercased()] {
            let text = String(UnicodeScalar(UInt32(scalar)).map(Character.init) ?? " ")
            return BrowserKey(keyCode: code, characters: text, charactersIgnoringModifiers: text,
                              modifiers: modifiers.union(scalar >= 0xF700 ? .function : []))
        }
        guard last.count == 1, let first = last.first, var key = character(first) else { return nil }
        key.modifiers.formUnion(modifiers)
        let plain = modifiers.contains(.shift) ? key.characters.uppercased() : key.characters
        key.charactersIgnoringModifiers = key.characters
        // A shortcut such as Meta+a sends the plain character; Control turns letters into control codes.
        if modifiers.contains(.control), let scalar = plain.lowercased().unicodeScalars.first,
           scalar.value >= 0x61, scalar.value <= 0x7A {
            key.characters = String(UnicodeScalar(scalar.value - 0x60).map(Character.init) ?? first)
        } else {
            key.characters = plain
        }
        return key
    }
}

// MARK: - Images

enum BrowserImage {
    enum Format: String { case png, jpeg }

    /// `image` scaled to at most `maxWidth` pixels wide and encoded.
    static func encode(_ image: CGImage, format: Format, quality: Int, width target: Int) throws -> Data {
        var image = image
        let width = max(1, min(target, image.width))
        if width != image.width {
            let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw BrowserScripts.Failure("the screenshot could not be encoded") }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { throw BrowserScripts.Failure("the screenshot could not be encoded") }
            image = scaled
        }
        let data = NSMutableData()
        let type = (format == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw BrowserScripts.Failure("the screenshot could not be encoded")
        }
        var properties: [CFString: Any] = [:]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = Double(min(max(quality, 1), 100)) / 100 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BrowserScripts.Failure("the screenshot could not be encoded") }
        return data as Data
    }
}

// MARK: - Snapshot diffs

enum BrowserSnapshotDiff {
    /// What changed between two snapshots, ignoring indentation and order:
    /// `-` lines left, `+` lines arrived, then how many stayed.
    static func diff(from old: [String], to new: [String]) -> String {
        let before = old.map { $0.trimmingCharacters(in: .whitespaces) }
        let after = new.map { $0.trimmingCharacters(in: .whitespaces) }
        var remaining = Dictionary(after.map { ($0, 1) }, uniquingKeysWith: +)
        var removed: [String] = []
        var kept = 0
        for line in before {
            if let count = remaining[line], count > 0 {
                remaining[line] = count - 1
                kept += 1
            } else {
                removed.append(line)
            }
        }
        var leftover = Dictionary(before.map { ($0, 1) }, uniquingKeysWith: +)
        var added: [String] = []
        for line in after {
            if let count = leftover[line], count > 0 {
                leftover[line] = count - 1
            } else {
                added.append(line)
            }
        }
        var lines = removed.map { "- " + $0 } + added.map { "+ " + $0 }
        lines.append(removed.isEmpty && added.isEmpty ? "= no change (\(kept) lines)" : "= \(kept) unchanged")
        return lines.joined(separator: "\n")
    }
}

extension JSONValue {
    /// The value as a number, whichever way JSON spelled it.
    var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .uint(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }
}
