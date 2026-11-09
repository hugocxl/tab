# Agent pane audit — 2026-11-09

This audit covers the native composer, transcript, images, prompt queue, provider
lifecycle, plan mode, questions, approvals, cancellation, reconnect and recovery.
It distinguishes implemented behavior, automated verification and checks requiring
physical microphone interaction. Release publication is verified separately from
implementation validation.

## Findings and resolution

| Priority | Finding | Implemented resolution |
| --- | --- | --- |
| P1 | Native questions could not be answered | Typed forms for Claude `AskUserQuestion` and Codex `item/tool/requestUserInput`, with choices, multiple selection, custom text, optional fields, secure fields, cancellation and provider resolution. Answers use a separate protocol operation from tool approvals. |
| P1 | Follow-up prompts lacked a durable queue | Server-owned FIFO with edit, reorder, remove, Send now and resume. Prompt text, attachment bytes, provider, model, effort and plan mode survive restarts. |
| P1 | An ambiguous send retry could execute twice | Client-generated submission ID and an acceptance ledger survive reconnects. Repeated identical submissions return the existing acceptance; conflicting reuse is rejected. Receipts survive editing and removal. |
| P1 | Drafts disappeared when the controller was disposed | Local draft storage retains text, citation attributes, attachments, submission identity and nonsecret form answers. Normal Quit waits for writes. Corrupt draft bytes are preserved in a recovery file. |
| P1 | Active steering lacked a session deadline | Steering now has the normal bounded submission deadline and generation fencing. Timeout stops the runtime and leaves uncertain delivery for explicit review. |
| P2 | Stop could immediately run the next queued prompt | Stop pauses the queue before interrupting. Recovery pauses pending work; interrupted delivery is never automatically replayed. Closing cancels queued work and releases its retained payloads. |
| P2 | Claude interruption silently discarded follow-ups | The transcript explicitly reports how many unconsumed follow-ups were cancelled. Earlier delivered rows remain available for review. |
| P2 | Plan output was display-only | Server-acknowledged plan mode, removable chip and Shift-Tab shortcut; provider mode settings are sent on the next turn. Explicit Claude plan-exit approval clears the mode. |
| P2 | Full access could answer a user decision | Native questions and Claude plan exit are excluded from automatic tool approval. |
| P2 | Citation prompts sometimes remained after sending | The acknowledgement clears only the captured attributed draft; later edits survive. |
| P2 | Screenshot attachments were heavily cropped | Whole-image fitting in wider, vertically stacked tiles with higher-resolution decoded previews. Original images remain available in the viewer. |
| P2 | Empty composer was bottom anchored | Vertically centered until content or pending work exists. |
| P2 | Composer did not follow supplied references | Continuous rounded border, plus attachment action, Plan chip, right-side model controls, microphone and waveform controls; narrow panes wrap controls. |
| P2 | Access selector added clutter | New conversations default to full access; visible selector and its slash action removed. Existing saved access policies remain intact. |
| P2 | Recovery actions were misleading | Refresh only refreshes state. Unsupported server actions explain the required update. Queued retries require review after uncertain delivery; edits can apply current model/effort/plan settings while retaining attachments. |
| P2 | Voice buttons had no backend | Microphone dictates to an editable draft using on-device recognition. Waveform reads the latest completed response aloud. Both stop explicitly, on hiding the pane and on disposal. |
| P3 | Waiting text only described permissions | Separate “Waiting for your answers” and “Waiting for approval” states. |
| P3 | Completed approvals disappeared | Decision rows remain visible. Question completion includes a nonsecret answer summary; private values are omitted. |

P1 concerns lost work, repeated execution or missing core interaction. P2 concerns
misleading state or significant usability gaps. P3 concerns traceability and polish.

## Prompt delivery contract

The app captures an `AgentPrompt` and saves its submission identity before requesting
server acceptance. The server writes a durable acceptance ledger before acknowledging
or delivering it. Disk writes use the persistence queue, outside input handling.
Snapshots contain queue descriptors rather than attachment payloads.

- **Idle Send:** accept durably, then deliver the first queued prompt.
- **Send while working or waiting:** accept into the queue, without resolving a
  permission or question and without silently steering the active turn.
- **Send now:** explicitly deliver to the active turn if provider/model/effort/mode
  match. Otherwise it must wait for a new turn. Busy startup and pending forms
  reject immediate delivery with an actionable error.
- **Repeated Return or reconnect:** the same captured prompt reuses its submission
  identity. Identical retries cannot append another accepted prompt.
- **Edit or reorder:** compare the row revision; a stale client cannot overwrite a
  newer edit or mutate a delivering item. Editing retains attachments. Model, effort
  and plan changes are optional, explicit replacements.
- **Turn completion:** one item is reserved for delivery at a time. Completion and
  Send now compete for the same reservation.
- **Stop:** pause before cancellation. A stopped or failed turn does not drain the
  queue. Resume is explicit.
- **Crash/restart:** queued items remain paused. A delivering item becomes uncertain
  and requires review before another attempt. Exactly-once provider execution cannot
  be inferred across a provider transport failure; the UI does not claim it.
- **Close:** stop the provider and cancel pending queue payloads. Stable receipts
  remain so an old client cannot recreate accepted work.
- **Storage failure:** do not deliver an unsaved acceptance. Keep the prompt and
  report the error; do not claim a successful durable send.

Bounds: 16 pending prompts, 64 MB of queued attachment bytes and 4,096 acceptance
receipts per conversation. A full ledger requires a new conversation rather than
silently forgetting older deduplication keys. Legacy `send` callers remain supported;
only the new `submit` path provides durable acceptance and retry deduplication.

## Question and approval contract

Forms retain local edits while unrelated snapshots stream. Multiple pending forms
are answered in sequence. Required fields are checked before submission; custom
answers remain available alongside offered choices. Secret fields use secure native
controls and are excluded from local persisted drafts and transcript answer summaries.
A successful response records completion before the form disappears. Repeating an
answer for a completed request returns its acknowledged state instead of answering
another request. Provider cancellation/resolution closes only the relevant request.

Claude receives `updatedInput.answers` in its native control response. Codex receives
its RPC answer object with the original numeric or string request ID. Full access
never chooses an answer. Generic MCP elicitation and unknown future provider RPCs
are not presented as supported native forms; unsupported operations receive explicit
protocol responses rather than leaving an invisible request waiting forever.

Forms and their metadata are bounded and counted in transcript budgets. Pending
forms retain their schema when later transcript output is trimmed. Completed
approvals and answer summaries stay visible within the retained transcript window.

## Plan mode and styling

Shift-Tab follows the shortcut catalog and only toggles from the composer, without
interfering with IME composition. The chip reflects server acknowledgement and
survives reconnect. A running turn's mode cannot silently change; stop first.
Claude gets native permission-mode changes; Codex gets `collaborationMode` with
explicit default-mode reset. Native support depends on installed provider versions.

New chats use full access; existing saved policies are retained. Removing the
selector does not silently alter an older conversation's policy.

The composer uses the app's continuous rounded contour, theme colors and AppIcon
assets. The empty state is centered. Queue controls use pencil, arrow and trash
icons; narrow panels wrap composer controls without overlapping. Question rows use
measured wrapping and a scrollable document. Image previews preserve aspect ratio,
with opening the original available for detailed screenshot reading.

## Draft and voice behavior

Draft files are private to the app profile and use restrictive file permissions.
Writes are debounced and revision ordered; submission and normal app termination
flush them. A sudden process kill can lose the latest typing inside the debounce
window, but accepted submissions retain their saved IDs. Corrupt bytes are moved to
a named recovery file before a new draft can replace them.

Dictation requests microphone and Speech permission only after a click, requires
on-device recognition support, and appends recognized text to the draft for review.
It never automatically sends a prompt. Unavailable language assets or permissions
produce an actionable message. Recording has a 60-second bound and stops when the
pane hides, closes or quits. Read-aloud is explicit and limited to 32,000 characters
of the latest completed assistant response. The waveform is read-aloud, not a claim
of a separate realtime voice-agent transport.

## Verification and remaining environmental checks

New regressions cover queue identity collisions, edited/completed receipts,
attachment recovery, stale revisions, FIFO/reordering, Stop/resume, Send now races,
failed persistence, restart without execution, form metadata under transcript
pressure, duplicate answer acknowledgement, provider RPC response shape, secret
redaction, draft restoration/corruption and narrow-panel geometry.

Both installed providers passed authenticated live smoke tests on 2026-11-09:
initial response, follow-up with changed reasoning effort and resumed conversation.
Structured forms, queue races and cancellation use deterministic provider peers;
the smoke prompts intentionally do not request tools or change files.

Native rendered fixtures cover 360, 680 and 1000 point composer widths and a narrow
question/queue panel. Actual microphone permission, language asset availability,
audio capture and audible playback still require a physical-device acceptance check.
That check is distinct from compiled API use and deterministic UI tests.

`scripts/validate.sh` passed after the final retry fix and integration with main:
warnings-as-errors build, 2,059 tests with 32 expected skips and no failures, debug bundling and code-signature
verification. The two authenticated provider smoke tests also passed separately.
Native fixture renders were inspected; live window automation was unavailable
(`cgWindowNotFound`). The earlier styling-only pass is superseded by this result.

## Source map

- `Sources/TabApp/Agents/AgentPaneController.swift`: commands, reconnect, drafts,
  question answers, queue actions, cancellation and voice control wiring.
- `Sources/TabApp/Agents/AgentInteractionPanels.swift`: native queue and question UI.
- `Sources/TabApp/Agents/AgentDraftStore.swift`: durable draft representation/store.
- `Sources/TabApp/Agents/AgentVoice.swift`: on-device dictation and read-aloud.
- `Sources/TabProtocol/AgentInteraction.swift`: prompt, queue and question schemas.
- `Sources/TabServer/Agents/AgentPromptInbox.swift`: acceptance ledger and recovery.
- `Sources/TabServer/Agents/AgentSessions.swift`: authoritative delivery lifecycle.
- `Sources/TabServer/Agents/AgentRuntime.swift`: Claude/Codex native interactions.

Provider collaboration and question shapes follow the
[official Codex app-server contract](https://learn.chatgpt.com/docs/app-server).
On-device dictation checks both recognition capability and the request flag, as
required by [Apple's Speech documentation](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition).
