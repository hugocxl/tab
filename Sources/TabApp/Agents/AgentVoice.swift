import AppKit
import AVFoundation
import Speech

/// Audio is used only after an explicit click. Recognition never sends audio off the Mac.
@MainActor
final class AgentVoice: NSObject, AVSpeechSynthesizerDelegate {
    enum State: Equatable { case idle, authorizing, listening, speaking }
    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?
    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var generation = UUID()
    private var authorization: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var partial = ""
    private let speech = AVSpeechSynthesizer()

    override init() { super.init(); speech.delegate = self }

    func toggleDictation() {
        if state == .listening || state == .authorizing { stop(); return }
        stop()
        let token = UUID(); generation = token; state = .authorizing
        authorization = Task { [weak self] in
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            guard microphone else {
                self.stop(); self.onError?("Allow microphone access for Tab in System Settings → Privacy & Security → Microphone."); return
            }
            let permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            guard permission == .authorized else {
                self.stop(); self.onError?("Allow speech recognition for Tab in System Settings → Privacy & Security → Speech Recognition."); return
            }
            do { try self.startRecognition(token: token) }
            catch { self.stop(); self.onError?(error.localizedDescription) }
        }
    }

    private func startRecognition(token: UUID) throws {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw ModelError("On-device dictation is unavailable for your current language. Enable Dictation in System Settings → Keyboard and download its language, then try again.")
        }
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ModelError("No microphone is available.") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.engine = engine; self.request = request; self.recognizer = recognizer
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let text { self.partial = text }
                if final || message != nil {
                    let hadText = !self.partial.isEmpty
                    self.stop()
                    if !hadText, let message { self.onError?("Dictation stopped: " + message) }
                }
            }
        }
        engine.prepare()
        try engine.start()
        state = .listening
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.generation == token else { return }
            self.stop()
        }
    }

    func toggleReading(_ text: String) {
        if state == .speaking { stop(); return }
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state = .speaking
        let utterance = AVSpeechUtterance(string: String(text.prefix(32_000)))
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        speech.speak(utterance)
    }

    func stop() {
        generation = UUID()
        authorization?.cancel(); authorization = nil
        deadline?.cancel(); deadline = nil
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil; recognizer = nil
        speech.stopSpeaking(at: .immediate)
        let text = partial; partial = ""; state = .idle
        if !text.isEmpty { onText?(text) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .speaking, !self.speech.isSpeaking else { return }
            self.state = .idle
        }
    }
}
