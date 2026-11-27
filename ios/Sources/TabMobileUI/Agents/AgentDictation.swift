import AVFoundation
import Speech
import UIKit

/// Dictates a message, as on the Mac: the microphone is used only after a
/// tap, recognition stays on the device, and a second tap (or a minute)
/// finishes it and hands over the text.
@MainActor
final class AgentDictation {
    enum State: Equatable { case idle, authorizing, listening }
    private(set) var state: State = .idle { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    /// The finished dictation.
    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var generation = UUID()
    private var authorization: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var partial = ""

    func toggle() {
        if state != .idle {
            stop()
            return
        }
        let token = UUID()
        generation = token
        state = .authorizing
        authorization = Task { [weak self] in
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard let self, generation == token else { return }
            guard microphone else {
                fail("Allow the microphone for Tab in Settings to dictate.")
                return
            }
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard generation == token else { return }
            guard speech == .authorized else {
                fail("Allow Speech Recognition for Tab in Settings to dictate.")
                return
            }
            do {
                try start(token: token)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func start(token: UUID) throws {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw DictationError("Dictation on this device isn't available for your language.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        // Asking an engine for its input without a microphone stalls until the audio server gives up.
        guard session.isInputAvailable else { throw DictationError("No microphone is available.") }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError("No microphone is available.") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.engine = engine
        self.request = request
        // The SDK refines the throwing tap for Swift but ships no Swift name for it yet;
        // its error slot imports as `()`, and failures throw.
        try engine.inputNode.__installTap(onBus: 0, bufferSize: 1024, format: format, error: (), block: { buffer, _ in
            request.append(buffer)
        })
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, generation == token else { return }
                if let text { partial = text }
                guard final || message != nil else { return }
                let heard = !partial.isEmpty
                stop()
                if !heard, let message { onError?("Dictation stopped: \(message)") }
            }
        }
        engine.prepare()
        try engine.start()
        state = .listening
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, generation == token else { return }
            stop()
        }
    }

    private func fail(_ message: String) {
        stop()
        onError?(message)
    }

    /// Finishes dictating, handing over what was heard.
    func stop() {
        generation = UUID()
        authorization?.cancel()
        authorization = nil
        deadline?.cancel()
        deadline = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        engine = nil
        request?.endAudio()
        request = nil
        recognition?.cancel()
        recognition = nil
        let text = partial
        partial = ""
        state = .idle
        if !text.isEmpty { onText?(text) }
    }
}

private struct DictationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
