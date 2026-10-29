import CGhosttyVT
import Foundation
import TabProtocol

/// Encodes mouse events for programs that track the mouse, remembering which
/// buttons are held so motion reports drags correctly.
final class Mouse {
    private let encoder: GhosttyMouseEncoder
    private let event: GhosttyMouseEvent
    private var held: [MouseButton] = []
    private var buffer = [CChar](repeating: 0, count: 64)

    init(size: Size) throws {
        var encoder: GhosttyMouseEncoder?
        var event: GhosttyMouseEvent?
        try Ghostty.check(ghostty_mouse_encoder_new(nil, &encoder), .create)
        guard let encoder else { throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue)) }
        guard ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS, let event else {
            ghostty_mouse_encoder_free(encoder)
            throw TerminalError(.create, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue))
        }
        self.encoder = encoder
        self.event = event
        resize(size)
    }

    deinit {
        ghostty_mouse_event_free(event)
        ghostty_mouse_encoder_free(encoder)
    }

    /// Positions are in cells, so one cell is one "pixel" for the encoder.
    func resize(_ size: Size) {
        var encoderSize = GhosttyMouseEncoderSize(
            size: MemoryLayout<GhosttyMouseEncoderSize>.size,
            screen_width: UInt32(size.cols), screen_height: UInt32(size.rows),
            cell_width: 1, cell_height: 1,
            padding_top: 0, padding_bottom: 0, padding_right: 0, padding_left: 0)
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &encoderSize)
        reset()
    }

    func reset() {
        held.removeAll()
        ghostty_mouse_encoder_reset(encoder)
    }

    func encode(_ mouse: MouseEvent, size: Size, terminal: GhosttyTerminal) throws -> Data {
        if let button = mouse.button {
            switch mouse.action {
            case .press where !held.contains(button): held.append(button)
            case .release: held.removeAll { $0 == button }
            default: break
            }
        }
        let action: GhosttyMouseAction
        let button: GhosttyMouseButton?
        switch mouse.action {
        case .press:
            action = GHOSTTY_MOUSE_ACTION_PRESS
            button = mouse.button.map(Self.button)
        case .release:
            action = GHOSTTY_MOUSE_ACTION_RELEASE
            button = mouse.button.map(Self.button)
        case .motion:
            action = GHOSTTY_MOUSE_ACTION_MOTION
            button = mouse.button.map(Self.button)
        case .scroll:
            guard let direction = mouse.scroll else { return Data() }
            action = GHOSTTY_MOUSE_ACTION_PRESS
            button = direction == .up ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
        }
        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)
        var pressed = !held.isEmpty
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
        ghostty_mouse_event_set_action(event, action)
        if let button {
            ghostty_mouse_event_set_button(event, button)
        } else {
            ghostty_mouse_event_clear_button(event)
        }
        ghostty_mouse_event_set_mods(event, Self.mods(mouse.modifiers))
        let column = min(mouse.col, size.cols &- 1)
        let row = min(mouse.row, size.rows &- 1)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: Float(column) + 0.5, y: Float(row) + 0.5))
        var length = 0
        var result = ghostty_mouse_encoder_encode(encoder, event, &buffer, buffer.count, &length)
        if result == GHOSTTY_OUT_OF_SPACE {
            buffer = [CChar](repeating: 0, count: max(length, buffer.count * 2))
            result = ghostty_mouse_encoder_encode(encoder, event, &buffer, buffer.count, &length)
        }
        try Ghostty.check(result, .input)
        return buffer.withUnsafeBytes { Data($0.prefix(length)) }
    }

    private static func button(_ button: MouseButton) -> GhosttyMouseButton {
        switch button {
        case .left: GHOSTTY_MOUSE_BUTTON_LEFT
        case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
        case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
        case .back: GHOSTTY_MOUSE_BUTTON_EIGHT
        case .forward: GHOSTTY_MOUSE_BUTTON_NINE
        }
    }

    /// Mouse reports carry only shift, alt and control.
    private static func mods(_ modifiers: KeyModifiers) -> GhosttyMods {
        Keyboard.mods(modifiers.intersection([.shift, .alt, .control]))
    }
}
