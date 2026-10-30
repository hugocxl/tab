# Agent Tabs

Agent Tabs put a native conversation alongside the project's terminal, editor
and browser panes. The transcript scrolls above a fixed bottom composer.
Open **New Agent Tab**, choose a model, reasoning effort and access mode in the bottom
composer, then send a prompt. Assistant responses render as selectable Markdown;
user messages use quiet bubbles and consecutive tool activity folds into compact
disclosures. Pending approval requests stay actionable; completed and automatic
approval confirmations are omitted from the conversation. Stop interrupts the current turn.
The conversation shares the terminal pane's background rather than drawing a
second inset backdrop.

## Provider setup

Install and sign in to the provider CLI on the Mac running the project's
`tabd`. A remote project uses the remote Mac's installation and credentials.
Check the CLI independently before opening a conversation:

```sh
claude --version
claude auth status
codex --version
codex login status
```

The app invokes the installed agent in the project's directory. The model menu
groups Claude Code and Codex presets from T3's model manifest, with a provider
default and **Custom model…** option for each. Presets are not an account-specific
availability check; the provider must support the selected model.

Model and effort changes apply to the next message and are saved with the
conversation when sent. **Default effort** delegates to the provider. The effort menu
offers the selected model's supported settings. Switching provider is available
until a provider conversation has been established; after that, open a new Agent
Tab to use another provider. Changing models within the same provider retains
the conversation's resume identity.

### Access modes

- **Auto** (default): approve Read, Glob, Grep, WebSearch and WebFetch permission
  requests automatically; ask before commands and changes.
- **Ask every time**: show every permission request received from the provider.
- **Full access**: explicitly allow tool permission requests, including commands
  and changes. Codex's next turn also runs without its native sandbox.

The selector remains available while waiting for approval. Changes are saved with
the conversation and can resolve eligible pending requests. Active turns retain
their existing provider sandbox; the new native provider policy applies on the
next turn. Providers can run tools that do not request permission; **Ask every
time** cannot create prompts for those tools. Structured questions are not
automatically answered by any access mode.

## Try it alongside a terminal

1. Open a project, then use **Agent Tab** in its empty view or **New Agent Tab**
   from the sidebar's **+** menu.
2. Choose a model and effort from the menus below the message editor.
3. Ask a simple question about the project. The response streams above the
   composer. Return sends; Shift+Return inserts a newline.
4. Open a terminal in the same project to keep a shell beside the conversation.
5. Try a task that needs a command or edit. When the provider asks for approval,
   use the inline Allow or Deny buttons. Provider rules may allow some tools
   without prompting.
6. Use Stop during a turn. Quit and reopen Tab to check reconnection to the
   server-owned conversation.

## Native chat behavior

This first version supports text conversations, streamed tool activity,
one-time tool approval or denial, interruption and provider conversation resume.
Responses update incrementally in stable native text views. Sending immediately
shows activity and Stop, including while the request is being accepted. Scrolling
away from the end preserves the reading position; **Scroll to end** resumes
following. Sending a new message returns to the latest turn. The bottom controls
remain accessible in narrow panes.

The transcript uses viewport virtualization. Offscreen native row views are released after a small cache;
lightweight row geometry and disclosure state remain. Width/content changes
invalidate the affected measurements, and streamed text does not remeasure
unchanged history. Expanded tool and completed-work logs have their own bounded
scroll viewports. Response sections cache their attributed content and measurements,
so appending to the final section does not rerender completed code/table sections.

Tool details retain input and output separately, with running, completed, failed,
denied and interrupted states when supplied by the provider. Completed turns fold
their commentary and tools into a **Worked for…** disclosure, leaving the final
answer visible. Durations use persisted server timestamps, so reconnecting does
not restart the clock. Older snapshots without timing retain ordinary activity
disclosures. Pending approvals never fold into a completed-work disclosure.

Responses and user messages have copy actions. Long user messages collapse with
**Show more** / **Show less**. File links open the project's editor at the linked
line; ordinary web and mail links use macOS link handling.

Structured provider questionnaires and other interactive extensions are reported
as unsupported; ask the agent to use ordinary chat for questions.

The server keeps a bounded transcript snapshot (up to 512 recent rows and about
512 KiB of text, with pending approvals retained). Older output can be trimmed;
this is not a full provider-history browser. The provider's own conversation ID
is stored separately for resume. The native view exposes the whole retained
snapshot through a virtualized scroll surface; it does not drop earlier rows
to limit native view counts. Pending approvals remain accessible in that history.

## T3 Code reference

This implementation follows [T3 Code](https://github.com/pingdotgg/t3code) at
revision `6fc9144a60c4a5f45089316ddd5f7371bafd3bf2`. Key references:

- `apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts`: Claude message
  normalization, permissions, interrupted turns and resume behavior.
- `apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts`: initialization,
  threads, turns, item updates, approvals and cancellation.
- `packages/effect-codex-app-server/src/protocol.ts`: newline-delimited JSON
  transport and request/response routing.
- `apps/server/src/orchestration-v2/testkit/fixtures/`: multi-turn conversations,
   streamed commands, restricted tools, interruptions and error scenarios.
- `apps/web/src/components/chat/ComposerSurface.tsx` and `ComposerControlsBar.tsx`:
  rounded, centered composer and quiet bottom-row model/effort controls.
- `apps/web/src/components/chat/TimelineUserMessageRow.tsx`,
  `MessagesTimeline.logic.ts`, and `apps/web/src/components/ChatMarkdown.tsx`:
  user bubbles, activity folding and document-like assistant responses.
- `apps/server/src/provider/model-manifest.json`: model presets and Claude
  reasoning-effort capabilities.

T3's server is TypeScript and its Claude adapter uses the Agent SDK. Tab adapts
these behaviors into Swift and drives the installed CLIs over pipes. Claude
SDK fixture operations such as `query.open` and `permission.request` are not
literal CLI wire messages; the Swift adapter uses Claude's bidirectional
`control_request` / `control_response` envelopes instead. Codex runs through
`codex app-server`.

T3's MIT notice is retained in `THIRD_PARTY_NOTICES.md` and bundled with the app.
Provider SDKs and executables are not vendored.

### Parity inventory

This is a native port in progress, not complete 1:1 T3 parity. The reviewed T3
revision contains substantially more than text chat. The following inventory
keeps unsupported behavior explicit rather than exposing controls without backing
functionality. Component paths below are relative to `apps/web/src/components/`.

| Area | Native implementation | Remaining T3 behavior / reference |
| --- | --- | --- |
| Streaming and resume | Stable partial-response text views; server-owned conversations and provider resume IDs; startup interruption; persisted turn timing | T3's thread lineage, fork/revert and checkpoint workflows are not implemented (`chat/ThreadLineageWorkflowRow.tsx`, `chat/TimelineAssistantRows.tsx`). |
| Work logs | Compact tool groups; expandable input/output; status and command exit code; ANSI colors; colored changes; file/web links; completed-work folding | Subagent thread navigation, richer checkpoint summaries and provider-specific interactive tools need additional protocol data (`chat/TimelineWorkEntryRow.tsx`, `chat/TimelineWorkGroupRows.tsx`). |
| Approval and composer | Native model/effort/access menus, inline permission actions, Stop, growing text input, plain-text paste, scroll following and scroll-to-end | Structured questionnaires, attachment/context/skill pickers and queued/steered messages are not implemented. |
| Markdown prose | Headings, paragraphs, inline emphasis/code, nested list markers, tasks, quotes, links | Full CommonMark/GFM block nesting, reference links, footnotes, heading-fragment navigation, alerts and HTML details remain (`ChatMarkdown.tsx`, `chat/MarkdownDetails.tsx`, `chat/markdownFragments.ts`). |
| Code | Tab's native syntax tokenizer, language/filename heading, exact-source copy, wrap toggle and horizontal scrolling | T3's larger grammar set, file icons, persistent wrap preference and guarded Run command action (`chat/MarkdownCodeBlock.tsx`). Nested code/table widgets inside list items or quotes are not equivalent yet. |
| Tables | Native columns/alignment, horizontal overflow, Markdown and CSV copy | Cross-cell selection and semantic table navigation (`chat/MarkdownTable.tsx`). |
| Links | HTTP/HTTPS/mailto; file paths and line navigation into the project editor | File chips, existence-aware previews/context menus, column positions, favicons, citations and thread/PR/context link presentations (`chat/MarkdownFileLink.tsx`, `chat/MarkdownExternalLink.tsx`, `chat/AssistantCitationChip.tsx`, `chat/MarkdownThreadLink.tsx`). |
| Copy and selection | Selectable prose/code, response/user copy, exact code copy, table export | Cross-section selection, Markdown-preserving selection copy and selection-to-citation toolbar (`chat/AssistantSelectionToolbar.tsx`, `apps/web/src/markdown-clipboard.ts`). |
| Math and diagrams | Source remains readable as text/code | Typeset math and Mermaid diagram/source switching (`chat/MarkdownMath.tsx`, `chat/MathTypeset.tsx`, `chat/MarkdownMermaidCodeBlock.tsx`, `chat/MermaidDiagram.tsx`). |
| Media and embedded apps | Text-only conversation transport | Images/audio/video, asset loading/retry, galleries/zoom, published HTML, MCP apps and artifact-template cards (`chat/ChatMarkdownMedia.tsx`, `chat/ExpandedImageDialog.tsx`, `chat/HtmlRenderFrame.tsx`, `chat/McpAppFrame.tsx`). |
| Rendering optimization | Viewport-virtualized rows/work logs, bounded native-view caches, row-identity scroll anchors, cached section content/measurements and selection retention | Last-block-only Markdown parsing and reduced-motion-aware streamed-block fades (`ChatMarkdown.tsx`, `apps/web/src/index.css`). |

## Troubleshooting

If a CLI hangs on `--version`, fix its installation or macOS launch approval
before testing it in an Agent Tab. A provider that cannot launch independently
cannot complete the app's protocol handshake. If the CLI launches but rejects a
conversation, check its sign-in status and the selected model.

Agent requests require a server built with Agent Tab support. When trying a
development build against an older running `tabd`, restart that server or use a
separate `TAB_DIR` development profile.

## Validation

Normal tests use offline protocol scenarios and stand-in processes. The live
smoke tests are opt-in: they use the signed-in provider account, run in an empty
temporary folder, request text-only replies and never approve tools. They check
two turns, then launch a new provider process and resume the conversation to
verify that its earlier context is retained.

```sh
TAB_AGENT_LIVE_TESTS=claude swift test --filter AgentLiveSmokeTests
TAB_AGENT_LIVE_TESTS=codex swift test --filter AgentLiveSmokeTests
```

Use `TAB_AGENT_LIVE_TESTS=all` to exercise both. Live tests incur normal provider
usage. Run `scripts/validate.sh` for the full build, offline suite and app bundle.

The October 30, 2026 running-app audit exercised live Claude streaming and Auto
web/read tools, expanded input/output logs, code copy/wrap, CSV table copying,
project file navigation and narrow layouts. Screenshots and the incremental
accessibility capture are under `build/validation/agent-ui/` and
`build/validation/live-stream-accessibility.log`. Completed approvals were absent
from the visible conversation. The original preview's provider conversation ID
and all 27 retained items survived relaunch. The 5,000-entry virtualization test
mounted 12 rows, retained 14 views and performed 14 initial measurements.
Live Codex validation remains blocked by the installed CLI hanging on launch.
