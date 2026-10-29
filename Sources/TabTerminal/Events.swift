import CGhosttyVT
import Foundation

/// Something the running program asked for, collected by `Terminal.takeEvents()`.
public enum TerminalEvent: Hashable, Sendable {
    case title(String)
    /// The working directory as the shell reported it (often a `file://` URI).
    case directory(String)
    case clipboardWrite(String)
    case bell
    case progress(ProgressUpdate)
}

/// Largest OSC 52 clipboard text accepted from a program.
public let maxClipboardText = 1024 * 1024

/// State the engine callbacks write into during `ghostty_terminal_vt_write`.
final class EngineCallbacks {
    var ptyOutput: [UInt8] = []
    var titleChanged = false
    var directoryChanged = false
    var bell = false
    var clipboardWrite: String?

    func install(on terminal: GhosttyTerminal) throws {
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        try Ghostty.check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata), .create)
        try set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(Self.writePty, to: UnsafeRawPointer.self))
        try set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(Self.titleChanged, to: UnsafeRawPointer.self))
        try set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(Self.pwdChanged, to: UnsafeRawPointer.self))
        try set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(Self.bellRang, to: UnsafeRawPointer.self))
        try set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(Self.clipboard, to: UnsafeRawPointer.self))
        try set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(Self.colorScheme, to: UnsafeRawPointer.self))
    }

    private func set(_ terminal: GhosttyTerminal, _ option: GhosttyTerminalOption, _ callback: UnsafeRawPointer) throws {
        try Ghostty.check(ghostty_terminal_set(terminal, option, callback), .create)
    }

    private static func callbacks(_ userdata: UnsafeMutableRawPointer?) -> EngineCallbacks? {
        guard let userdata else { return nil }
        return Unmanaged<EngineCallbacks>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
        guard let callbacks = callbacks(userdata), let data, length > 0 else { return }
        callbacks.ptyOutput.append(contentsOf: UnsafeBufferPointer(start: data, count: length))
    }

    private static let titleChanged: GhosttyTerminalTitleChangedFn = { _, userdata in
        callbacks(userdata)?.titleChanged = true
    }

    private static let pwdChanged: GhosttyTerminalPwdChangedFn = { _, userdata in
        callbacks(userdata)?.directoryChanged = true
    }

    private static let bellRang: GhosttyTerminalBellFn = { _, userdata in
        callbacks(userdata)?.bell = true
    }

    private static let clipboard: GhosttyTerminalClipboardWriteFn = { _, userdata, write in
        guard let callbacks = callbacks(userdata), let write else { return }
        let result = callbacks.acceptClipboard(write.pointee)
        var reply = GhosttyClipboardWriteReply(
            size: MemoryLayout<GhosttyClipboardWriteReply>.size, result: result, remember: false)
        write.pointee.reply?(write, &reply)
    }

    private func acceptClipboard(_ write: GhosttyClipboardWrite) -> GhosttyClipboardWriteResult {
        guard write.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD, let contents = write.contents else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
        }
        let entries = UnsafeBufferPointer(start: contents, count: write.contents_len)
        guard let text = entries.first(where: { Ghostty.string($0.mime) == "text/plain" }) else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
        }
        guard let bytes = text.data.ptr, text.data.len > 0, text.data.len <= maxClipboardText,
              let string = String(bytes: UnsafeBufferPointer(start: bytes, count: text.data.len), encoding: .utf8)
        else {
            return GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
        }
        clipboardWrite = string
        return GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
    }

    private static let colorScheme: GhosttyTerminalColorSchemeFn = { terminal, _, scheme in
        var background = GhosttyColorRgb()
        let result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT, &background)
        switch result {
        case GHOSTTY_SUCCESS: scheme?.pointee = ColorSchemeReport.scheme(for: background)
        case GHOSTTY_NO_VALUE: scheme?.pointee = GHOSTTY_COLOR_SCHEME_DARK
        default: return false
        }
        return true
    }
}

enum ColorSchemeReport {
    static func scheme(for background: GhosttyColorRgb) -> GhosttyColorScheme {
        var color = background
        return ghostty_color_perceived_luminance(&color) > 0.5 ? GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK
    }

    static func encode(background: ThemeColor) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 32)
        var written = 0
        let result = ghostty_color_scheme_report_encode(
            scheme(for: GhosttyColorRgb(background)), &buffer, buffer.count, &written)
        guard result == GHOSTTY_SUCCESS else { return [] }
        return buffer.prefix(written).map { UInt8(bitPattern: $0) }
    }
}
