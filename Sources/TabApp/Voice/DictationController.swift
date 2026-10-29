import AppKit
import Foundation
import TabCore

/// The live terminal a dictation types into: the pane and the exact
/// attachment it showed when dictation started. A new connection or another
/// terminal in the pane is a different target, so text never reaches a
/// terminal it wasn't meant for.
public struct DictationTarget: Hashable, Sendable {
    public var pane: String
    /// Such as the server, the session's channel and the connection's generation.
    public var attachment: String

    public init(pane: String, attachment: String) {
        self.pane = pane
        self.attachment = attachment
    }
}

/// The shell side of dictation.
@MainActor
public protocol DictationHost: AnyObject {
    /// The focused live terminal, or `nil` when none is focused or attached.
    var dictationTarget: DictationTarget? { get }
    /// The view the overlay floats over, at its bottom center: the window's
    /// content area.
    var dictationOverlayContainer: NSView? { get }
    /// The voice section of the current settings.
    var voiceSettings: VoiceSettings { get }
    /// Types `text` into `target` as a paste (bracketed when its program asks
    /// for that), then Return when `sendReturn`. Throws when it can't be
    /// delivered.
    func insertDictation(_ text: String, sendReturn: Bool, into target: DictationTarget) async throws
    /// Shows an error banner.
    func showDictationError(_ message: String)
    /// The overlay closed: give the terminal its focus back.
    func dictationDidEnd()
}

/// Runs one dictation at a time into the focused live terminal (Toggle
/// Voice Recording, Cmd+Shift+I).
@MainActor
public final class DictationController {
    public weak var host: DictationHost?
    private let makeRecorder: @MainActor (VoiceSettings) -> DictationRecorder
    private let now: () -> Date

    private var session: Session?

    private struct Session {
        var target: DictationTarget
        var recorder: DictationRecorder
        var state: DictationState
        var view: DictationIndicatorView
        var clock: Timer?
        var autoSend: Bool
    }

    /// - Parameter makeRecorder: the recorder for the settings; tests pass a fake.
    public init(host: DictationHost?,
                makeRecorder: @escaping @MainActor (VoiceSettings) -> DictationRecorder = { SpeechRecorder(language: $0.language, model: $0.model) },
                now: @escaping () -> Date = Date.init) {
        self.host = host
        self.makeRecorder = makeRecorder
        self.now = now
    }

    /// Whether the overlay is up.
    public var isActive: Bool { session != nil }

    /// The current dictation's state, if any.
    public var state: DictationState? { session?.state }

    /// Starts dictating into the focused live terminal, or cancels the
    /// dictation under way.
    public func toggle() {
        if session != nil {
            cancel()
        } else {
            start()
        }
    }

    public func start() {
        guard session == nil, let host else { return }
        guard let target = host.dictationTarget else {
            host.showDictationError("Open a live terminal before starting dictation.")
            return
        }
        let settings = host.voiceSettings
        let recorder = makeRecorder(settings)
        let view = DictationIndicatorView()
        session = Session(target: target, recorder: recorder, state: DictationState(), view: view, clock: nil,
                          autoSend: settings.autoSend)
        view.onCancel = { [weak self] in self?.cancel() }
        view.onPause = { [weak self] in self?.togglePause() }
        view.onFinish = { [weak self] in self?.finish() }
        recorder.onEvent = { [weak self, weak recorder] event in
            guard let self, let recorder, self.session?.recorder === recorder else { return }
            self.handle(event)
        }
        if let container = host.dictationOverlayContainer {
            view.present(in: container)
            view.window?.makeFirstResponder(view)
        }
        session?.clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        render()
        recorder.start()
    }

    /// Return or Finish: waits for the final transcript, then types it.
    public func finish() {
        apply { $0.requestFinish(at: now()) }
    }

    /// Space or Pause: releases the microphone, or takes it again.
    public func togglePause() {
        apply { $0.togglePause(at: now()) }
    }

    /// Escape, Cancel or Close: discards the recording.
    public func cancel() {
        close()
    }

    /// Call when the focused pane, its terminal or its connection changes;
    /// a dictation whose target is gone is cancelled.
    public func targetDidChange() {
        guard let session, host?.dictationTarget != session.target else { return }
        cancel()
    }

    // MARK: Driving the state

    private func tick() {
        apply { $0.tick(at: now()) }
    }

    private func handle(_ event: DictationEvent) {
        let date = now()
        apply { $0.apply(event, at: date) }
    }

    private func apply(_ change: (inout DictationState) -> DictationEffect) {
        guard var current = session else { return }
        let effect = change(&current.state)
        session = current
        switch effect {
        case .none:
            break
        case .finishRecorder:
            current.recorder.finish()
        case .pauseRecorder(let paused):
            current.recorder.pause(paused)
        case .stopRecorder:
            current.recorder.cancel()
            current.clock?.invalidate()
            session?.clock = nil
        case .deliver(let text):
            deliver(text, session: current)
            return
        }
        render()
    }

    private func render() {
        guard let session else { return }
        session.view.show(session.state, elapsed: session.state.elapsed(at: now()), autoSend: session.autoSend)
    }

    private func deliver(_ text: String, session: Session) {
        close()
        guard let host else { return }
        guard host.dictationTarget == session.target else { return }
        let target = session.target
        let sendReturn = session.autoSend
        Task { [weak self] in
            do {
                try await host.insertDictation(text, sendReturn: sendReturn, into: target)
            } catch {
                self?.host?.showDictationError("Dictation delivery failed: \(error.localizedDescription)")
            }
        }
    }

    private func close() {
        guard let session else { return }
        self.session = nil
        session.clock?.invalidate()
        session.recorder.onEvent = nil
        session.recorder.cancel()
        session.view.dismiss()
        host?.dictationDidEnd()
    }
}
