import Foundation

/// Where a dictation is.
public enum DictationPhase: Equatable, Sendable {
    /// Asking for permissions and starting the microphone.
    case starting
    case recording
    /// The microphone is released; the transcript so far is kept.
    case paused
    /// Recording ended; the recognizer is writing its final words.
    case transcribing
    /// The text went to the terminal, or the dictation was cancelled.
    case finished
    case failed
}

/// What a recorder reports, on the main actor.
public enum DictationEvent: Equatable, Sendable {
    /// The microphone is live (again).
    case recording
    /// The microphone is released while paused.
    case paused
    /// The transcript so far, corrections merged.
    case transcript(String)
    /// The input level, 0…1.
    case level(Float)
    /// Recognition ended with this transcript.
    case final(String)
    case failed(String)
}

/// What the controller does after a state change.
public enum DictationEffect: Equatable, Sendable {
    case none
    /// Ask the recorder to stop listening and finish recognition.
    case finishRecorder
    /// Pause or resume the recorder.
    case pauseRecorder(Bool)
    /// Stop everything and insert the text into the target terminal.
    case deliver(String)
    /// Stop the recorder; the indicator keeps showing the error.
    case stopRecorder
}

/// One dictation's state, free of audio and UI so its rules can be tested:
/// Finish waits for recording to start and then for the final transcript,
/// Pause is refused while transcribing, an empty result is reported instead
/// of inserted, a failure is reported even after Finish, and recording ends
/// on its own at the time limit.
public struct DictationState: Equatable, Sendable {
    /// The longest a dictation records, paused time excluded.
    public static let limit: TimeInterval = 10 * 60
    public static let noSpeech = "No speech detected. Try again or press Esc to close."

    public private(set) var phase: DictationPhase = .starting
    public private(set) var transcript = ""
    public private(set) var level: Float = 0
    public private(set) var error: String?
    public private(set) var finishRequested = false
    private var recordedBefore: TimeInterval = 0
    private var recordingSince: Date?

    public init() {}

    /// A recorder that couldn't start.
    public init(failure: String) {
        phase = .failed
        error = failure
    }

    /// Time spent recording, paused time excluded.
    public func elapsed(at now: Date) -> TimeInterval {
        recordedBefore + (recordingSince.map { max(now.timeIntervalSince($0), 0) } ?? 0)
    }

    /// Whether the recorder still runs and can report.
    public var isActive: Bool {
        phase == .starting || phase == .recording || phase == .paused || phase == .transcribing
    }

    // MARK: User commands

    /// Return or the Finish button. Ignored until recording starts.
    public mutating func requestFinish(at now: Date) -> DictationEffect {
        guard phase == .recording || phase == .paused, !finishRequested else { return .none }
        stopClock(at: now)
        finishRequested = true
        phase = .transcribing
        level = 0
        return .finishRecorder
    }

    /// Space or the Pause button: pauses or resumes.
    public mutating func togglePause(at now: Date) -> DictationEffect {
        switch phase {
        case .recording:
            stopClock(at: now)
            phase = .paused
            level = 0
            return .pauseRecorder(true)
        case .paused:
            return .pauseRecorder(false)
        default:
            return .none
        }
    }

    /// The clock ticked; recording finishes on its own at the limit.
    public mutating func tick(at now: Date) -> DictationEffect {
        guard phase == .recording, elapsed(at: now) >= Self.limit else { return .none }
        return requestFinish(at: now)
    }

    // MARK: Recorder events

    public mutating func apply(_ event: DictationEvent, at now: Date) -> DictationEffect {
        guard isActive else { return .none }
        switch event {
        case .recording:
            guard !finishRequested else { return .none }
            phase = .recording
            if recordingSince == nil { recordingSince = now }
            return .none
        case .paused:
            guard !finishRequested else { return .none }
            stopClock(at: now)
            phase = .paused
            level = 0
            return .none
        case .transcript(let text):
            transcript = text
            return .none
        case .level(let value):
            guard phase == .recording else { return .none }
            level = min(max(value, 0), 1)
            return .none
        case .final(let text):
            transcript = text
            guard finishRequested else {
                // Recognition ended on its own; the words wait for Finish.
                return .none
            }
            return complete()
        case .failed(let message):
            stopClock(at: now)
            phase = .failed
            error = message
            level = 0
            return .stopRecorder
        }
    }

    private mutating func complete() -> DictationEffect {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        level = 0
        guard !text.isEmpty else {
            phase = .failed
            error = Self.noSpeech
            return .stopRecorder
        }
        phase = .finished
        return .deliver(text)
    }

    private mutating func stopClock(at now: Date) {
        recordedBefore = elapsed(at: now)
        recordingSince = nil
    }
}

/// Merges the recognizer's running results into one transcript. A result
/// usually revises the words heard so far, but after a pause it can start
/// over with only the new words; those earlier words are kept instead of lost
/// or repeated.
struct DictationTranscript {
    private var committed = ""
    private var partial = ""

    mutating func update(_ incoming: String) -> String {
        let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty && (incoming.isEmpty || shouldCommitPartial(incoming)) {
            if !committed.isEmpty { committed += " " }
            committed += partial
        }
        partial = incoming
        return [committed, partial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func shouldCommitPartial(_ incoming: String) -> Bool {
        if incoming.hasPrefix(partial) { return false }
        let words = { (text: String) in
            text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        }
        let previous = words(partial)
        let next = words(incoming)
        if previous.count <= 1 || next.isEmpty { return false }
        if previous.first != next.first { return true }
        return previous.count > 2 && next.count > 1 && previous[1] != next[1]
    }
}

/// Picks the recognition language.
enum DictationLocale {
    static let fallback = "en-US"

    /// The base language, with the old codes Apple still uses mapped.
    static func base(_ locale: String) -> String {
        let id = locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        switch id {
        case "nb": return "no"
        case "iw": return "he"
        case "jv": return "jw"
        default: return id
        }
    }

    /// The system's language among `available`; else US English, or the
    /// first one.
    static func select(_ available: [String], preferences: [String]) -> String? {
        if let system = system(available, preferences: preferences) { return system }
        return available.contains(fallback) ? fallback : available.sorted().first
    }

    /// The system's language among `available`, as the user's preferred
    /// languages order them; US English stands for plain English.
    static func system(_ available: [String], preferences: [String]) -> String? {
        guard let matched = Bundle.preferredLocalizations(from: available, forPreferences: preferences).first,
              available.contains(matched)
        else { return nil }
        let requested = preferences.contains(matched)
        if available.contains(fallback) && !requested && base(matched) == base(fallback) { return fallback }
        return matched
    }
}

/// The end of a long transcript, so the indicator shows the latest words.
enum DictationText {
    static func tail(_ text: String, limit: Int = 180) -> String {
        guard text.count > limit else { return text }
        let cut = text.suffix(limit)
        let start = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[start...]
    }

    static func clock(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
