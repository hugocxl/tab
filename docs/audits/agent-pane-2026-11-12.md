# Agent pane audit — 2026-11-12

## Scope and visual contract

This pass covers the composer, active work, prompt queue, questions and approvals,
transcript navigation, saved conversations, task/subagent visibility, historical
changes, draft recovery, accessibility, and rendering performance. The requested
improvements are delivered together, including diff comments.

Keep the existing AppTheme palette, fonts, icons, glass presets, corner treatments,
and spacing conventions. New functionality uses native controls and existing Tab
components. No renderer redesign, provider protocol replacement, dependencies,
conversation rewind, or child-transcript implementation is included.

## Findings and resolutions

| Priority | Finding | Classification | Resolution |
| --- | --- | --- | --- |
| P1 | Closing an idle parent can stop running background agents without confirmation. | Verified in the close predicate; regression test added. | Running subagents participate in the existing cancellable close transaction. |
| P2 | Typing a follow-up hides Stop. | Verified in the action-state test and baseline fixtures. | Stop remains beside Send while drafting during active work; neither action clears the draft merely by becoming visible. |
| P2 | Panels retain previous frames when the available height reaches zero. | Source-level risk, covered by a resize regression. | Hidden panels get zero frames; visible ancillary panels share a bounded scrolling container when space is constrained. |
| P2 | Queue editing blocks the application and uses a fixed text field for potentially long prompts. | Verified in the editor implementation. | Nonblocking sheet with a scrollable multiline editor; attachment retention and revision-checked updates remain unchanged. |
| P2 | Queue updates reconstruct every row and action, dropping keyboard focus. | Verified in the update implementation. | Reuse rows/buttons by prompt identity and refresh callbacks to the current revision; reveal actions on keyboard focus. |
| P2 | Resume only exposes 40 entries per provider and drops the server's truncation flag. | Verified in the history adapter and menu construction. | Search all returned entries, preserve newest-first ordering and provider/date labels, and explain the server's 200-result limit when truncated. |
| P2 | Historical changes cannot be annotated and sent back with reliable location context. | Feature opportunity; existing diffs already use checkpoints. | Select old/new lines or ranges, add/edit/delete comments, persist them with the local draft, and append one review request to the composer without sending it. |
| P3 | Long conversations require repeated scrolling or text search to locate prompts. | Feature opportunity; Find already exists. | Searchable prompt outline plus previous/next prompt actions using retained item IDs and existing anchors. |
| P3 | Todo progress disappears into folded or offscreen work. | Feature opportunity; typed todo cards already exist. | Compact progress control for the latest incomplete reported list; click to reveal its source. Idle/failed work is labelled paused. |
| P3 | Subagent rows have mouse/AX press actions but no keyboard focus path. | Verified in the row implementation. | Focusable rows with Return/Space activation and the existing accent focus treatment. |
| P2 | Historical diff controls can inherit dark system appearance on a light conversation surface. | Found in light-theme native renders. | Propagate the conversation appearance to the diff window and controls; retain the existing palette and native control style. |
| P3 | Question validation gives a general error without navigating to the missing answer. | Verified in form validation. | Reveal/focus the first unanswered required question and announce the error; nonsecret form drafts remain intact. |

P1 means work can be lost or stopped unexpectedly. P2 concerns control, reliable
state, or substantial workflow friction. P3 concerns navigation and accessibility.

## Behavior and compatibility

- Sending during work still queues; Stop still pauses the queue before interruption.
  Existing acceptance IDs, uncertain-delivery review, reconnect fencing, and secure
  question handling are unchanged.
- Navigation searches retained user prompts, including attachment-only prompts.
  It stops at boundaries, keeps stable item identities, and uses deliberate transcript
  navigation rather than enabling automatic following. `/outline`, `/previous-prompt`,
  and `/next-prompt` complement the existing Find action. New command-palette actions
  are configurable in ShortcutCatalog without new default key bindings.
- History search is local to the returned list. The server's existing bounded folder
  scan and import semantics remain authoritative; this UI does not claim unlimited
  history or search conversation bodies.
- Task progress uses the latest valid `todo_list` item. A complete/absent list hides
  the control, and changing conversations clears derived state. No polling, provider
  calls, or inferred completion is introduced.
- Diff comments carry checkpoint, file, side, line range, retained source excerpt,
  and text. Unified and split views share the same source identities. Hunk gaps and
  non-source rows cannot become comments. Binary/unavailable diffs have no selectable
  lines; truncated diffs explicitly retain their preview warning. Long source
  excerpts identify their truncation.
- Comments persist as an optional field in the existing local draft. Older draft
  files remain readable. Closing a diff window retains comments. Adding comments
  to the composer appends to existing attributed text, preserves attachments, clears
  only the consumed checkpoint comments, and never submits to a provider.
- No wire-format or protocol-version change is needed. The app's history callback
  now retains the already-existing AgentHistoryReply instead of discarding metadata.

## Audit coverage

| Surface | Evidence and acceptance |
| --- | --- |
| Composer, model/effort, plan mode, attachments, suggestions | Existing composer/controller/attachment/citation tests; new Stop-with-draft behavior; before/after fixtures. |
| Queue, questions, approvals | Existing delivery and form regressions; new row-identity, multiline-sheet cancellation, close-protection, and crowded-layout checks. |
| Transcript, media, links, code, tables, diagrams | Existing rendering, clipboard, selection, search, media, anchor, and virtualization suites; preserve their implementations. |
| Navigation/history/progress | Stable-ID/boundary tests, history search beyond the former cap, latest-list completion/reset tests, native picker/progress fixtures. |
| Review and recovery | Old/new line mapping, invalid/hunk-gap ranges, comment persistence/legacy decoding, and composer append-without-send regressions. |
| Large conversations | Existing thousands-of-messages and hundreds-of-tools virtualization tests; progress parses only when its source changes, and navigation does not mount the whole transcript. |
| Local/remote ownership | Existing project/session-scoping and server/client suites; history and checkpoint fetching still use the owning server. |
| Accessibility | Focus/activation tests for added controls and question validation; live VoiceOver and physical-device speech checks remain separate acceptance evidence. |

## Verification

Baseline: 44 focused UI tests passed before changes. Native fixtures were captured
at 360, 680 and 1000 points. The three empty-composer fixtures and the questions/queue
fixture are byte-for-byte identical after the change. Populated fixtures intentionally
change the composer control row to keep Stop beside Send.

The full `scripts/validate.sh` run passed: 2,100 tests, 33 skips, no failures,
warnings-as-errors build, debug bundle, and signature validation. A subsequent
focused validation passed 114 tests covering the modified agent flows, shortcuts,
conversation search, and virtualization. After the final keyboard-side-selection
correction, `scripts/validate.sh --filter 'AgentRefinementTests|AgentCheckpointDiffWindowTests'`
also passed: 16 tests, one opt-in render skipped, no failures, followed by bundle and
signature validation. The render test had already passed with capture enabled.
The 5,000-entry virtualization fixture
retained 18 views and mounted 15 rows, with 18 initial measurements.

Native light/dark fixtures for history, constrained progress/queue layout, and
historical diff review were inspected. Light-theme inspection found and verified
the appearance-propagation correction described above. Existing transcript pixels
remain unchanged: differences in the six populated baseline fixtures are confined
to the composer control row. Evidence is retained under the ignored build directory:

- `build/validation/agent-pane/before/` and `after/`: baseline and final renders.
- `build/validation/agent-pane/refinements/`: the new interaction surfaces.
- `build/validation/agent-pane/pixel-comparison.txt`: changed-pixel bounds.
- `build/validation/agent-pane/full-test.log` and `focused-test.log`: broad test evidence.
- `build/validation/agent-pane/final-regression-test.log` and `final-validation.log`:
  final-source regression checks and the `validation passed` result.

The isolated worktree development app was launched. Live computer-use inspection
failed with `cgWindowNotFound` using both its bundle ID and exact bundle path, so
live mouse/keyboard acceptance is unverified. Physical microphone capture, audible
playback, VoiceOver, and remote-machine interactions were not manually exercised.
The deterministic native tests and renders are evidence distinct from those checks.

Before committing 0.96.0, the changes were rebased onto 0.95.1 and the full
`scripts/validate.sh` gate passed again: 2,106 tests, 33 skips, zero failures,
warnings-as-errors build, debug bundle and signature validation.
