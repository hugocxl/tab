import XCTest
@testable import TabServer
import TabProtocol

private let detector = AgentDetector()

private func classify(_ provider: AgentProvider, _ screen: String, title: String = "",
                      progress: String = "") -> AgentDetector.Classification? {
    detector.classify(provider, DetectionText(screen: screen, title: title, progress: progress))
}

private func idle(_ explicit: Bool = false) -> AgentDetector.Classification {
    .init(state: .idle, explicitIdle: explicit)
}

final class DetectionManifestTests: XCTestCase {
    func testEveryBundledManifestCompilesWithRules() throws {
        for (provider, file) in AgentDetector.manifestFiles {
            let rules = try DetectionManifest.compile(try AgentDetector.bundledManifest(file))
            XCTAssertFalse(rules.isEmpty, provider.rawValue)
            XCTAssertEqual(rules.map(\.priority), rules.map(\.priority).sorted(by: >), provider.rawValue)
        }
    }

    func testRejectsInvalidPatternsAndUnknownRegions() {
        let badRegex = #"{"rules":[{"id":"a","state":"working","priority":1,"region":"whole_recent","regex":["("]}]}"#
        XCTAssertThrowsError(try DetectionManifest.compile(Data(badRegex.utf8)))
        let badRegion = #"{"rules":[{"id":"a","state":"working","priority":1,"region":"middle","contains":["x"]}]}"#
        XCTAssertThrowsError(try DetectionManifest.compile(Data(badRegion.utf8)))
    }
}

final class DetectionClassificationTests: XCTestCase {
    func testBundledManifestsClassifyProviderScreens() {
        let fixtures: [(AgentProvider, String, String, AgentState)] = [
            (.claude, "", "⠋ Working", .working),
            (.claude, "", "✳ Ready", .idle),
            (.codex, "", "Action Required", .blocked),
            (.codex, "", "⠋ Fix tests", .working),
            (.codex, "› ", "Fix tests", .idle),
            (.openCode, "△ Permission required", "", .blocked),
            (.openCode, "esc to interrupt", "", .working),
            (.cursor, "Waiting for approval\nRun this command?\nRun (once) (y)", "", .blocked),
            (.cursor, "ctrl+c to stop", "", .working),
            (.copilot, "enter to select · esc to cancel", "", .blocked),
            (.copilot, "◎ Waiting for background agents", "", .working),
            (.droid, "↑↓ navigate · enter select · esc cancel", "", .blocked),
            (.droid, "esc to stop", "", .working),
            (.pi, "── ⠋ Working ──────────", "", .working),
            (.grok, "┃  2 (○) Yes, proceed", "", .blocked),
            (.grok, "", "⠋ grok", .working),
            (.grok, "", "grok", .idle),
            (.kiro, "requires approval\nyes, single permission", "", .blocked),
            (.kiro, "kiro is working", "", .working),
            (.kiro, "ask a question or describe a task\n/copy to clipboard", "", .idle),
            (.xal, "! Approval needed · choose above", "", .blocked),
            (.xal, "? Input needed · answer above", "", .blocked),
            (.xal, "⠋ Working · Esc interrupt", "", .working),
            (.xal, "✓ Finished in 4s", "", .idle),
            (.xal, "! Interrupted after 4s", "", .unknown),
            (.antigravity, "requesting permission for:\ndo you want to proceed?", "", .blocked),
            (.antigravity, "⠋ Thinking", "", .working),
            (.ohMyPi, " say hello\n  ⎋ Working…", "", .working),
            (.ohMyPi,
             "╭─── ✎ Write: 🗒 test.txt · 1 line ─────╮\n│   1 hello                         ╯\n[↑ ↓ to navigate, ⏎ to select, ⎋ to deny]",
             "", .blocked),
            (.ohMyPi, " π · ◉ glm-5.2 · 🗑 /tmp ↳ codesh-pr · ⑂ fix/1x-icon-import", "", .idle),
        ]
        for (provider, screen, title, expected) in fixtures {
            XCTAssertEqual(classify(provider, screen, title: title)?.state, expected, "\(provider): \(screen) / \(title)")
        }
        for (provider, _) in AgentDetector.manifestFiles {
            XCTAssertEqual(classify(provider, "New unrecognized UI"), idle(), provider.rawValue)
        }
    }

    func testOldPromptTextDoesNotOverrideLiveXalStatus() {
        let screen = "! Approval needed · choose above\n" + String(repeating: "old transcript\n", count: 80)
            + "\n✓ Finished in 4s"
        XCTAssertEqual(classify(.xal, screen), idle(true))
    }

    func testOmpTitleSpinnerVariantsDoNotConfuseLabelsWithState() {
        for spinner in ["⠋", "⠁", "◔", "-", "\\", "|", "/", ":"] {
            for label in ["", " Inspect files"] {
                let title = "π \(spinner)\(label)"
                XCTAssertEqual(classify(.ohMyPi, "", title: title), .init(state: .working, explicitIdle: false), title)
            }
        }
        for title in ["π: ⠋ Inspect files", "π !important", "π >file", "π ⠋file", "Session π ⠋ Inspect files"] {
            XCTAssertEqual(classify(.ohMyPi, "", title: title), idle(), title)
        }
    }

    func testOmpWorkingOscSignalsDoNotHideVisibleApproval() {
        for screen in [
            "[↑ ↓ to navigate, ⏎ to select, ⎋ to deny]",
            "╭─ Allow tool: bash ─╮\n│ ❯ Approve │\n│ Deny │\n│ ↑ ↓ navigate  ⏎ select  ⎋ cancel │",
        ] {
            XCTAssertEqual(classify(.ohMyPi, screen, title: "π ⠋ Inspect files", progress: "4;1;-1"),
                           .init(state: .blocked, explicitIdle: false), screen)
        }
    }

    func testOmpGenericSelectorsAndApprovalTextDoNotRequestAttention() {
        for screen in [
            "Choose a session\n❯ project-a\n  project-b\n↑ ↓ navigate  ⏎ select  ⎋ cancel",
            "Allow tool: bash\nApprove or Deny the command to continue.\n↑ ↓ navigate  ⏎ select  ⎋ cancel",
            "Allow tool: bash\n❯ Approve\n  Deny\nCommand approved.\n  ⎋ Applying changes",
            "Confirm action\n❯ Approve\n  Deny\n↑ ↓ navigate  ⏎ select  ⎋ cancel",
        ] {
            XCTAssertNotEqual(classify(.ohMyPi, screen)?.state, .blocked, screen)
        }
    }

    func testOmpWorkingMentionsDoNotStartACycle() {
        let oldSpinner = "⠋ Working… [esc]\n" + String(repeating: "answer\n", count: 12) + "π › model"
        for screen in ["The tool printed Working...", "> Working...", "Working...\nAnswer\n$ ", "  ⎋ ", oldSpinner] {
            XCTAssertEqual(classify(.ohMyPi, screen), idle(), screen)
        }
    }

    func testDetectRecognizesProgramAndKeepsPreviousStateWhenARuleAsksTo() throws {
        XCTAssertNil(detector.detect(DetectionInput(screen: "esc to interrupt", title: "", progress: "", program: "zsh"),
                                     previous: nil))
        let working = detector.detect(
            DetectionInput(screen: "⠋ Working · Esc interrupt", title: "", progress: "", program: "xal"), previous: nil)
        XCTAssertEqual(working, DetectionResult(provider: .xal, state: .working))

        let skipping = try XCTUnwrap(skipRule())
        let custom = AgentDetector(rules: [.xal: skipping])
        let kept = custom.detect(DetectionInput(screen: "transcript viewer", title: "", progress: "", program: "xal"),
                                 previous: working)
        XCTAssertEqual(kept, DetectionResult(provider: .xal, state: .working, keepsPreviousState: true))
    }

    private func skipRule() throws -> [DetectionRule] {
        let json = #"{"rules":[{"id":"viewer","state":"idle","priority":10,"region":"whole_recent","skip_state_update":true,"contains":["Transcript Viewer"]}]}"#
        return try DetectionManifest.compile(Data(json.utf8))
    }
}

final class DetectionIdentityTests: XCTestCase {
    func testProcessIdentityUsesExecutablePositionsNotPromptText() {
        XCTAssertEqual(AgentDetector.identify(name: "node",
                                              arguments: ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js"]),
                       .codex)
        XCTAssertEqual(AgentDetector.identify(name: "python3", arguments: ["python3", "/opt/bin/claude"]), .claude)
        XCTAssertNil(AgentDetector.identify(name: "node", arguments: ["node", "my-app.js", "claude"]))
        XCTAssertNil(AgentDetector.identify(name: "bash", arguments: ["bash", "-c", "echo codex"]))
        XCTAssertEqual(AgentDetector.identify(name: "omp", arguments: ["omp"]), .ohMyPi)
        XCTAssertEqual(AgentDetector.identify(name: "node", arguments: ["node", "/usr/local/bin/oh-my-pi"]), .ohMyPi)
        XCTAssertNil(AgentDetector.identify(name: "tmux", arguments: ["tmux", "codex"]))
        XCTAssertNil(AgentDetector.identify(name: "tmux", arguments: ["tmux", "omp"]))
        XCTAssertEqual(AgentDetector.identify(
            name: "node", arguments: ["node", "/home/u/.local/share/cursor-agent/versions/1.0/index.js"]), .cursor)
        XCTAssertEqual(AgentDetector.identify(program: "claude"), .claude)
    }
}

final class DetectionRegionTests: XCTestCase {
    private func region(_ screen: String, _ spec: String) -> String {
        String(DetectionRegion.text(DetectionText(screen: screen, title: "T", progress: "P"), spec: spec))
    }

    func testRegionsCutTheScreenLikeTheReference() {
        let screen = "a\n\nb\nc\n"
        XCTAssertEqual(region(screen, "osc_title"), "T")
        XCTAssertEqual(region(screen, "osc_progress"), "P")
        XCTAssertEqual(region(screen, "bottom_lines(2)"), "b\nc\n")
        XCTAssertEqual(region(screen, "bottom_non_empty_lines(3)"), "a\n\nb\nc\n")
        XCTAssertEqual(region(screen, "bottom_non_empty_lines(0)"), "")
        XCTAssertEqual(region(screen, "top_non_empty_lines(2)"), "a\n\nb\n")
        XCTAssertEqual(region(screen, "top_non_empty_lines(02)"), "")
        XCTAssertEqual(region(screen, "nonsense"), "")

        let codex = "• Ran tests\nok\n› Ask Codex\n  model"
        XCTAssertEqual(region(codex, "after_last_prompt_marker"), "  model")
        XCTAssertEqual(region(codex, "before_current_prompt_marker"), "• Ran tests\nok\n")
        XCTAssertEqual(region(codex, "whole_recent_without_current_prompt_marker"), "")
        XCTAssertEqual(region(codex, "current_prompt_block_marker"), "• Ran tests")
        XCTAssertEqual(region(codex, "after_current_prompt_block_marker"), codex)
        XCTAssertEqual(region("› old\n• newer", "whole_recent_without_current_prompt_marker"), "› old\n• newer")

        let box = "above\n──────\nbody\n──────\nfooter"
        XCTAssertEqual(region(box, "prompt_box_body"), "body\n")
        XCTAssertEqual(region(box, "above_prompt_box"), "above\n")
        XCTAssertEqual(region(box, "last_non_empty_above_prompt_box"), "above")
        XCTAssertEqual(region(box, "after_last_horizontal_rule"), "footer")
        XCTAssertTrue(DetectionRegion.isHorizontalRule("─── title"))
        XCTAssertFalse(DetectionRegion.isHorizontalRule("── title"))
        XCTAssertTrue(DetectionRegion.isHorizontalRule("  ──  "))
    }
}

final class DetectionTrackerTests: XCTestCase {
    private var tracker = AgentStateTracker()
    private let start = ContinuousClock.now

    private func update(_ provider: AgentProvider?, _ screen: String, title: String = "", progress: String = "",
                        at milliseconds: Int) -> Bool {
        tracker.update(detector: detector, provider: provider, screen: screen, title: title, progress: progress,
                       now: start + .milliseconds(milliseconds))
    }

    func testRedrawsUnmatchedScreensAndExitsDoNotInventCompletion() {
        XCTAssertFalse(update(.xal, "⠋ Working · Esc interrupt", at: 0))
        XCTAssertEqual(tracker.state, .working)
        XCTAssertFalse(update(.xal, "", at: 100))
        XCTAssertEqual(tracker.state, .working)
        XCTAssertFalse(update(.xal, "✓ Finished in 4s", at: 200))
        XCTAssertTrue(update(.xal, "✓ Finished in 4s", at: 500))
        XCTAssertFalse(update(.xal, "⠋ Working · Esc interrupt", at: 1000))
        XCTAssertFalse(update(nil, "", at: 2000))
        XCTAssertEqual(tracker.state, .unknown)
    }

    func testFallbackProvidersCompleteOnlyAfterStableIdle() {
        let cases: [(AgentProvider, String)] = [
            (.openCode, "esc to interrupt"), (.cursor, "ctrl+c to stop"), (.copilot, "esc to cancel"),
            (.droid, "esc to stop"), (.pi, "Working..."), (.ohMyPi, "  ⎋ Working…"), (.antigravity, "⠋ Thinking"),
        ]
        for (provider, working) in cases {
            tracker = AgentStateTracker()
            XCTAssertFalse(update(provider, "Ready", at: 0))
            XCTAssertFalse(update(provider, working, at: 0))
            XCTAssertEqual(tracker.state, .working, "\(provider)")
            XCTAssertFalse(update(provider, "Response complete", at: 0))
            XCTAssertEqual(tracker.state, .working)
            XCTAssertTrue(update(provider, "Response complete", at: 700), "\(provider)")
            XCTAssertFalse(update(provider, "Response complete", at: 1000))
        }
    }

    func testLongBlankRedrawPreservesCycleAndBlockedState() {
        for (initial, expected) in [("⠋ Working · Esc interrupt", AgentState.working),
                                    ("! Approval needed · choose above", .blocked)] {
            tracker = AgentStateTracker()
            _ = update(.xal, initial, at: 0)
            for elapsed in [100, 900] {
                XCTAssertFalse(update(.xal, "", at: elapsed))
                XCTAssertEqual(tracker.state, expected)
            }
            XCTAssertFalse(update(.xal, "✓ Finished in 4s", at: 1000))
            XCTAssertEqual(update(.xal, "✓ Finished in 4s", at: 1300), expected == .working)
        }
    }

    func testOmpOscTitleStatesOverrideStaleScreenAndProgress() {
        let steps: [(Int, String, AgentState, Bool)] = [
            (0, "π ⠋ Inspect files", .working, false),
            (100, "π ⠙ Inspect files", .working, false),
            (200, "π ! Inspect files", .blocked, false),
            (300, "π ⠹ Inspect files", .working, false),
            (400, "π > Inspect files", .working, false),
            (700, "π > Inspect files", .idle, true),
            (1000, "π > Inspect files", .idle, false),
        ]
        for (elapsed, title, expected, completed) in steps {
            XCTAssertEqual(update(.ohMyPi, "  ⎋ Inspecting files\n π · model · project", title: title,
                                  progress: "4;1;-1", at: elapsed), completed, title)
            XCTAssertEqual(tracker.state, expected, title)
        }
    }

    func testOmpProgressReportsSupportDisabledTitleState() {
        let steps: [(Int, String, AgentState, Bool)] = [
            (0, "4;1;-1", .working, false),
            (1000, "4;1;-1", .working, false),
            (1100, "4;0;0", .working, false),
            (1800, "4;0;0", .idle, true),
            (2000, "4;0;0", .idle, false),
        ]
        for (elapsed, progress, expected, completed) in steps {
            XCTAssertEqual(update(.ohMyPi, "Session output", title: "π: Inspect files", progress: progress,
                                  at: elapsed), completed, progress)
            XCTAssertEqual(tracker.state, expected, progress)
        }
    }

    func testOmpHeadlessProgressCompletesWithProgressStillInHistory() {
        runScreens(.ohMyPi, [
            (0, "Working...\n\n", .working, false),
            (1000, "", .working, false),
            (1100, "Working...\nAnswer", .working, false),
            (1800, "Working...\nAnswer", .idle, true),
            (2000, "Working...\nAnswer\n$ ", .idle, false),
        ])
    }

    func testOmpTrimmedIntentPreservesWorkUntilApprovalAndCompletion() {
        runScreens(.ohMyPi, [
            (0, "  ⎋ Working…", .working, false),
            (100, "  ⎋ Inspecting files ", .working, false),
            (200, "  ⎋ Inspecting files", .working, false),
            (1000, "  ⎋ Inspecting files", .working, false),
            (1100, "  ⎋ Inspecting files\n[↑ ↓ to navigate, ⏎ to select, ⎋ to deny]", .blocked, false),
            (1200, "  ⎋ Applying changes", .working, false),
            (1300, " π · model · project", .working, false),
            (1600, " π · model · project", .idle, true),
            (2000, " π · model · project", .idle, false),
        ])
    }

    /// The Rust test also checks the activity events; those belong to the
    /// server core's activity store. The detector side is the same.
    func testOmpCurrentApprovalBlocksUntilWorkResumes() {
        let approval = """
            ╭─ Allow tool: bash ───────────────────────────╮
            │ Command: echo hello                         │
            │ ❯ Approve                                   │
            │   Deny                                      │
            │ ↑ ↓ navigate  ⏎ select  ⎋ cancel             │
            ╰─────────────────────────────────────────────╯
              ⎋ Working…
             ⠋ 2s · model · project
            """
        let denySelected = approval.replacingOccurrences(of: "❯ Approve", with: "  Approve")
            .replacingOccurrences(of: "  Deny", with: "❯ Deny")
            .replacingOccurrences(of: "⠋ 2s", with: "⠙ 3s")
        runScreens(.ohMyPi, [
            (0, "  ⎋ Working…", .working, false),
            (100, approval, .blocked, false),
            (1000, denySelected, .blocked, false),
            (1100, "  ⎋ Applying changes", .working, false),
            (1200, " π · model · project", .working, false),
            (1500, " π · model · project", .idle, true),
            (2000, " π · model · project", .idle, false),
        ])
    }

    func testOmpLegacySpinnerSurvivesAnimationAndCompletesOnce() {
        runScreens(.ohMyPi, [
            (0, "⠋ Working… [esc]\nπ › model", .working, false),
            (1000, "⠙ Working… [esc]\nπ › model", .working, false),
            (1100, "Answer\nπ › model", .working, false),
            (1800, "Answer\nπ › model", .idle, true),
            (2000, "Answer\nπ › model", .idle, false),
        ])
    }

    func testCodexAnimatedIdlePromptFinishesOnceWithoutWaitingForAStaticScreen() {
        _ = update(.codex, "• Working (1s • esc to interrupt)", title: "Fix tests", at: 0)
        XCTAssertEqual(tracker.state, .working)
        var completions = 0
        for tick in 1 ... 20 {
            let screen = "All tests passed.\n› Ask Codex to do anything \(String(repeating: " ", count: tick))⠈\n"
                + "  gpt-6-astra low · ~/project"
            if update(.codex, screen, title: "Fix tests", at: tick * 100) { completions += 1 }
        }
        XCTAssertEqual(tracker.state, .idle)
        XCTAssertEqual(completions, 1)
    }

    private func runScreens(_ provider: AgentProvider, _ steps: [(Int, String, AgentState, Bool)],
                            file: StaticString = #filePath, line: UInt = #line) {
        for (elapsed, screen, expected, completed) in steps {
            XCTAssertEqual(update(provider, screen, at: elapsed), completed, screen, file: file, line: line)
            XCTAssertEqual(tracker.state, expected, screen, file: file, line: line)
        }
    }
}
