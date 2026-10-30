import AVFoundation
import Foundation
import Speech
import TabCore

/// Records speech and reports `DictationEvent`s on the main actor.
@MainActor
public protocol DictationRecorder: AnyObject {
    var onEvent: ((DictationEvent) -> Void)? { get set }
    /// Asks for permissions, then starts listening.
    func start()
    /// Releases the microphone while paused, keeping the recognition going.
    func pause(_ paused: Bool)
    /// Stops listening and lets recognition write its final words.
    func finish()
    /// Stops everything; no event follows.
    func cancel()
}

/// Dictation with the system's on-device speech recognition and
/// `AVAudioEngine` capture. Nothing leaves this Mac.
@MainActor
public final class SpeechRecorder: DictationRecorder {
    /// How long Finish waits for the recognizer's final result.
    static let finalization: TimeInterval = 2

    public var onEvent: ((DictationEvent) -> Void)?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = DictationTranscript()
    private var latest = ""
    private var finishing = false
    private var stopped = false
    private var paused = false
    private var finalizationTimer: Timer?
    private var configurationObserver: NSObjectProtocol?

    public init() {}

    /// The on-device request, built without acquiring the microphone.
    static func recognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        return request
    }

    public func start() {
        Task { [weak self] in
            do {
                try await Self.authorize()
                guard let self, !self.stopped else { return }
                let locale = await Task.detached(priority: .userInitiated) {
                    Self.systemLocale()
                }.value
                guard !self.stopped else { return }
                try self.begin(locale: locale)
            } catch {
                self?.fail((error as? DictationError)?.message ?? error.localizedDescription)
            }
        }
    }

    public func pause(_ paused: Bool) {
        guard !stopped, !finishing, engine != nil, paused != self.paused else { return }
        self.paused = paused
        if paused {
            stopCapture()
            emit(.paused)
            return
        }
        do {
            try startCapture()
            emit(.recording)
        } catch {
            fail("The microphone could not start recording")
        }
    }

    public func finish() {
        guard !stopped, !finishing else { return }
        finishing = true
        stopCapture()
        request?.endAudio()
        finalizationTimer = Timer.scheduledTimer(withTimeInterval: Self.finalization, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.complete() }
        }
    }

    public func cancel() {
        guard !stopped else { return }
        stopped = true
        tearDown()
    }

    // MARK: Permissions and language

    private static func authorize() async throws {
        let app = Release.appName
        let microphone: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = true
        case .notDetermined: microphone = await AVCaptureDevice.requestAccess(for: .audio)
        default: microphone = false
        }
        guard microphone else {
            throw DictationError("Microphone access is disabled. Enable \(app) in System Settings → Privacy & Security → Microphone.")
        }
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard speech == .authorized else {
            throw DictationError("Speech recognition access is disabled. Enable \(app) in System Settings → Privacy & Security → Speech Recognition.")
        }
    }

    /// The installed on-device language that follows the system's.
    nonisolated static func systemLocale() -> String? {
        let ids = SFSpeechRecognizer.supportedLocales()
            .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .map(\.identifier)
        return DictationLocale.select(ids, preferences: Locale.preferredLanguages)
    }

    // MARK: Recording

    private func begin(locale: String?) throws {
        guard let locale else {
            throw DictationError("No on-device speech language is installed. Add one in System Settings → Keyboard → Dictation.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            throw DictationError("This language is unavailable for speech recognition")
        }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw DictationError("On-device speech recognition is unavailable for this language. Add another in System Settings → Keyboard → Dictation.")
        }
        recognizer.defaultTaskHint = .dictation
        let request = Self.recognitionRequest()
        self.request = request
        engine = AVAudioEngine()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text, isFinal, error in
            self?.recognized(text, isFinal: isFinal, error: error)
        })
        try startCapture()
        emit(.recording)
    }

    private func startCapture() throws {
        guard let engine, let request else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw DictationError("No microphone is available")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.tap(request: request) { [weak self] level in self?.emit(.level(level)) })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError("The microphone could not start recording")
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fail("The audio input changed. Finish or cancel dictation, then try again.")
            }
        }
    }

    /// Stops the engine, which turns the microphone off.
    private func stopCapture() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func recognized(_ text: String?, isFinal: Bool, error: String?) {
        guard !stopped else { return }
        if let text {
            latest = transcript.update(text)
            emit(.transcript(latest))
            if isFinal {
                if finishing {
                    complete()
                } else {
                    emit(.final(latest))
                }
                return
            }
        }
        guard let error else { return }
        if finishing {
            complete()
        } else {
            fail(error)
        }
    }

    private func complete() {
        guard !stopped else { return }
        let text = latest
        stopped = true
        tearDown()
        onEvent?(.final(text))
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        tearDown()
        onEvent?(.failed(message))
    }

    private func emit(_ event: DictationEvent) {
        guard !stopped else { return }
        onEvent?(event)
    }

    private func tearDown() {
        finalizationTimer?.invalidate()
        finalizationTimer = nil
        stopCapture()
        task?.cancel()
        task = nil
        request = nil
        engine = nil
    }

    // MARK: Off the main thread

    /// Forwards the recognizer's results to the main actor.
    private nonisolated static func resultHandler(
        _ deliver: @escaping @MainActor (String?, Bool, String?) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            DispatchQueue.main.async { deliver(text, isFinal, message) }
        }
    }

    /// Feeds audio to the recognizer and reports the level about ten times a
    /// second, on the audio thread.
    private nonisolated static func tap(
        request: SFSpeechAudioBufferRecognitionRequest,
        level: @escaping @MainActor (Float) -> Void
    ) -> AVAudioNodeTapBlock {
        let meter = LevelMeter()
        return { buffer, _ in
            request.append(buffer)
            guard let value = meter.measure(buffer) else { return }
            DispatchQueue.main.async { level(value) }
        }
    }
}

/// Turns audio buffers into a 0…1 level, at most every 100 ms.
private final class LevelMeter: @unchecked Sendable {
    private var lastReport = DispatchTime(uptimeNanoseconds: 0)

    func measure(_ buffer: AVAudioPCMBuffer) -> Float? {
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds &- lastReport.uptimeNanoseconds >= 100_000_000,
              let samples = buffer.floatChannelData?[0], buffer.frameLength > 0
        else { return nil }
        lastReport = now
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(max((decibels + 50) / 45, 0), 1)
    }
}

/// Why dictation couldn't start or go on, in words for the user.
struct DictationError: Error, LocalizedError {
    var message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}
