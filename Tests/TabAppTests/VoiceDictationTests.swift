import AppKit
import TabCore
import Speech
import XCTest
@testable import TabApp

final class VoiceDictationStateTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    private func recording(_ transcript: String) -> DictationState {
        var state = DictationState()
        _ = state.apply(.recording, at: start)
        _ = state.apply(.transcript(transcript), at: start)
        return state
    }

    func testFinishWaitsForTheFinalTranscript() {
        var state = recording("hello")
        XCTAssertEqual(state.requestFinish(at: start), .finishRecorder)
        XCTAssertEqual(state.phase, .transcribing)
        XCTAssertEqual(state.requestFinish(at: start), .none)
        XCTAssertEqual(state.apply(.transcript("hello wor"), at: start), .none)
        XCTAssertEqual(state.apply(.final("hello world "), at: start), .deliver("hello world"))
        XCTAssertEqual(state.phase, .finished)
        XCTAssertEqual(state.apply(.final("again"), at: start), .none)
    }

    func testFinishIsIgnoredUntilRecordingStarts() {
        var state = DictationState()
        XCTAssertEqual(state.requestFinish(at: start), .none)
        XCTAssertEqual(state.togglePause(at: start), .none)
        XCTAssertEqual(state.phase, .starting)
    }

    func testFinishWithoutSpeechReportsItInsteadOfInserting() {
        var state = recording("")
        _ = state.requestFinish(at: start)
        XCTAssertEqual(state.apply(.final("  "), at: start), .stopRecorder)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.error, DictationState.noSpeech)
    }

    func testFailureIsReportedEvenAfterFinishWasRequested() {
        var state = recording("hello")
        _ = state.requestFinish(at: start)
        XCTAssertEqual(state.apply(.failed("Microphone recording stopped. Try again."), at: start), .stopRecorder)
        XCTAssertEqual(state.error, "Microphone recording stopped. Try again.")
        XCTAssertEqual(state.apply(.final("hello"), at: start), .none)
    }

    func testRecognitionEndingByItselfWaitsForFinish() {
        var state = recording("hello")
        XCTAssertEqual(state.apply(.final("hello there"), at: start), .none)
        XCTAssertEqual(state.phase, .recording)
        XCTAssertEqual(state.requestFinish(at: start), .finishRecorder)
        XCTAssertEqual(state.apply(.final("hello there"), at: start), .deliver("hello there"))
    }

    func testPausedTimeIsNotCountedAndPauseIsRefusedWhileTranscribing() {
        var state = recording("a")
        let paused = start.addingTimeInterval(5)
        XCTAssertEqual(state.togglePause(at: paused), .pauseRecorder(true))
        XCTAssertEqual(state.elapsed(at: paused.addingTimeInterval(100)), 5, accuracy: 0.001)
        XCTAssertEqual(state.togglePause(at: paused), .pauseRecorder(false))
        let resumed = paused.addingTimeInterval(100)
        _ = state.apply(.recording, at: resumed)
        XCTAssertEqual(state.elapsed(at: resumed.addingTimeInterval(2)), 7, accuracy: 0.001)
        _ = state.requestFinish(at: resumed)
        XCTAssertEqual(state.togglePause(at: resumed), .none)
    }

    func testRecordingFinishesByItselfAtTheTimeLimit() {
        var state = recording("long talk")
        XCTAssertEqual(state.tick(at: start.addingTimeInterval(DictationState.limit - 1)), .none)
        XCTAssertEqual(state.tick(at: start.addingTimeInterval(DictationState.limit)), .finishRecorder)
        XCTAssertEqual(state.phase, .transcribing)
    }

    func testRecognitionCorrectionsReplacePartialWordsWithoutDuplicates() {
        for (partial, incoming) in [
            ("hello", "Hello world"),
            ("hello world", "Hello, world!"),
            ("weather", "Whether we go"),
            ("Let's try this", "let’s try this again"),
            ("hello world", "hello there"),
        ] {
            var transcript = DictationTranscript()
            _ = transcript.update(partial)
            XCTAssertEqual(transcript.update(incoming), incoming)
        }
        var transcript = DictationTranscript()
        _ = transcript.update("one two three")
        XCTAssertEqual(transcript.update("one more"), "one two three one more")
    }

    func testLanguageSelectionPrefersTheSystemThenUSEnglish() {
        let available = ["de-DE", "en-US", "fr-FR"]
        XCTAssertEqual(DictationLocale.select(available, preferences: ["fr-FR"]), "fr-FR")
        XCTAssertEqual(DictationLocale.select(available, preferences: ["ja-JP"]), "en-US")
        XCTAssertNil(DictationLocale.select([], preferences: ["en-US"]))
    }

    func testSystemLanguageFollowsThePreferredLanguages() {
        XCTAssertEqual(DictationLocale.system(["en-GB", "en-US", "fr-FR"], preferences: ["fr-FR", "en-GB"]), "fr-FR")
        XCTAssertEqual(DictationLocale.system(["en-GB", "en-US"], preferences: ["en-GB"]), "en-GB")
        XCTAssertEqual(DictationLocale.system(["en-GB", "en-US"], preferences: ["en"]), "en-US")
    }

    func testLongTranscriptsShowTheirLatestWords() {
        let text = (1...100).map(String.init).joined(separator: " ")
        let tail = DictationText.tail(text, limit: 20)
        XCTAssertTrue(tail.hasPrefix("…"))
        XCTAssertTrue(tail.hasSuffix("99 100"))
        XCTAssertLessThanOrEqual(tail.count, 21)
        XCTAssertEqual(DictationText.clock(605), "10:05")
    }
}

@MainActor
private final class FakeRecorder: DictationRecorder {
    var onEvent: ((DictationEvent) -> Void)?
    var started = false
    var finishing = false
    var cancelled = false
    var paused: [Bool] = []

    func start() { started = true }
    func pause(_ paused: Bool) { self.paused.append(paused) }
    func finish() { finishing = true }
    func cancel() { cancelled = true }
}

@MainActor
private final class FakeDictationHost: DictationHost {
    var dictationTarget: DictationTarget? = DictationTarget(pane: "p1", attachment: "local/1/gen1")
    var dictationOverlayContainer: NSView? = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var inserted: [(String, DictationTarget)] = []
    var errors: [String] = []
    var ended = 0
    var failDelivery = false

    func insertDictation(_ text: String, into target: DictationTarget) async throws {
        if failDelivery { throw DictationError("connection closed") }
        inserted.append((text, target))
    }

    func showDictationError(_ message: String) { errors.append(message) }
    func dictationDidEnd() { ended += 1 }
}

@MainActor
final class VoiceDictationControllerTests: XCTestCase {
    private var host: FakeDictationHost!
    private var recorders: [FakeRecorder] = []
    private var controller: DictationController!

    override func setUp() async throws {
        host = FakeDictationHost()
        recorders = []
        controller = DictationController(host: host, makeRecorder: { [unowned self] in
            let recorder = FakeRecorder()
            recorders.append(recorder)
            return recorder
        })
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testRecognitionStaysOnThisMac() {
        XCTAssertTrue(SpeechRecorder.recognitionRequest().requiresOnDeviceRecognition)
    }

    func testDictationNeedsALiveTerminal() {
        host.dictationTarget = nil
        controller.toggle()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(host.errors, ["Open a live terminal before starting dictation."])
    }

    func testFinishedTextGoesToTheTarget() async {
        controller.toggle()
        let recorder = recorders[0]
        XCTAssertTrue(recorder.started)
        recorder.onEvent?(.recording)
        recorder.onEvent?(.transcript("ls -la"))
        controller.finish()
        XCTAssertTrue(recorder.finishing)
        recorder.onEvent?(.final("ls -la"))
        await settle()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(host.inserted.map(\.0), ["ls -la"])
        XCTAssertEqual(host.ended, 1)
    }

    func testOnlyOneDictationRunsAndToggleCancelsIt() {
        controller.start()
        controller.start()
        XCTAssertEqual(recorders.count, 1)
        controller.toggle()
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(recorders[0].cancelled)
    }

    func testChangingTheTargetCancelsAndALateResultIsDropped() async {
        controller.toggle()
        let recorder = recorders[0]
        recorder.onEvent?(.recording)
        controller.finish()
        host.dictationTarget = DictationTarget(pane: "p1", attachment: "local/1/gen2")
        controller.targetDidChange()
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(recorder.cancelled)
        recorder.onEvent?(.final("late text"))
        await settle()
        XCTAssertTrue(host.inserted.isEmpty)
    }

    func testPauseReleasesTheMicrophoneThroughTheRecorder() {
        controller.toggle()
        let recorder = recorders[0]
        recorder.onEvent?(.recording)
        controller.togglePause()
        XCTAssertEqual(controller.state?.phase, .paused)
        controller.togglePause()
        XCTAssertEqual(recorder.paused, [true, false])
    }

    func testFailedDeliveryIsReported() async {
        host.failDelivery = true
        controller.toggle()
        recorders[0].onEvent?(.recording)
        controller.finish()
        recorders[0].onEvent?(.final("hello"))
        await settle()
        XCTAssertEqual(host.errors, ["Dictation delivery failed: connection closed"])
    }

    func testAFailureStaysOnScreenUntilClosed() {
        controller.toggle()
        recorders[0].onEvent?(.failed("Microphone access is disabled."))
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.state?.error, "Microphone access is disabled.")
        controller.cancel()
        XCTAssertFalse(controller.isActive)
    }
}
