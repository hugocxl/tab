# Agent Tabs

Agent Tabs put a conversation pane alongside the project's terminal, editor
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
groups the catalogs reported by Claude Code and Codex, with **Refresh models…**
to request an updated catalog.

Model and effort changes apply to the next message and are saved with the
conversation when sent. **Auto** reasoning delegates to the provider's configured default. The effort menu
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

## Chat behavior

### Composer context and attachments

The bottom model, reasoning and access pickers use content-sized labels, icons
and vertical separators, wrapping in narrow panes. The reasoning picker supports
keyboard navigation in a native popover. Its `Auto` value follows the provider's
configured reasoning level. The model menu offers provider-reported models;
provider-resolved model metadata supplies the current label when available.
Both model lists and reasoning options load directly from the project server's
installed Claude Code and Codex. Catalogs refresh automatically and through
**Refresh models…**; cached provider catalogs support offline use. New model IDs
and reasoning levels require no Tab release. Provider-advertised defaults are
marked when available.

The context ring reports the latest provider-reported context usage. Click it for
token counts and capacity. Unknown capacity stays unknown rather than displaying
an estimated percentage; usage is retained across reconnects and restarts.

- Type **@** to search project files and other open agent conversations in the
  project. Up/Down selects a result; Return or Tab inserts it; Escape dismisses
  suggestions. File mentions retain their project-relative paths. Thread mentions
  include a bounded text excerpt as an attachment, so the provider receives context.
- Type **/** for `/model`, `/effort`, `/access`, `/attach`, `/stop` and `/clear`.
  These perform native actions; `/clear` clears the draft and its attachments.
  Provider-specific commands without a native implementation are not advertised.
- Installed **/skill:name** entries come from the project's server: Claude's
  `.claude/skills` and project `.claude/commands`, or Codex's `.agents/skills`
  and `~/.codex/skills`. Project definitions take precedence over global ones.
  Selecting a skill includes its instructions and original resource directory.
- Use the **paperclip**, drop files onto the input box, or paste copied files and
  images. Attachment tiles show filenames, sizes and image thumbnails; each has
  a remove action. Attachment-only messages are supported. Failed sends retain
  draft attachments. Sent images render above the message bubble, or without a
  bubble when sent alone; multiple images share a rounded collage. Click an image
  for the source image viewer with zoom, PNG Copy and original-byte Save. Files sent alone use separate 256-point cards; files accompanying text
  use compact preview/download rows above the body. PDF, Markdown and text files
  open in an isolated native preview, depending on the file type; Copy and Save
  use scoped native byte access.
- Attach up to **10 files totaling 8 MiB**. Bytes travel to the project server,
  including remote hosts, and are staged privately for provider access. Claude
  receives native image/PDF blocks; Codex receives native image inputs and file
  paths for other formats. Unsupported image formats are converted when possible.
  Attachment data is not embedded in retained transcript snapshots. New sends
  also persist a private per-message payload index. The `agentAttachment` request
  fetches bytes by conversation, message and attachment ID after checking retained
  transcript ownership; it never accepts a path. This survives daemon reloads and
  supports remote previews. Older sends without an index remain unavailable to
  this retrieval path and show an unavailable-preview state. Image thumbnails
  decode off the main thread and use bounded pixel sizes;
  native attachment payload reads share a 32 MiB cache.

The conversation body is a native AppKit transcript. The composer, provider
processes and persisted conversations are owned by Tab. The body runs no
JavaScript; audio, video and HTML file previews open in separate, isolated
preview windows.

Responses stream into stable rows: a partial answer updates its text views in
place. The transcript virtualizes retained history, mounting only the rows near
the viewport, folds completed work and preserves selection, expanded tools and
reading position during updates. **Scroll to end** resumes following; sending a
new message returns to the latest turn. The server still bounds the available
history; this is not a full provider-history browser.

Conversation colors come from the app's theme, including syntax and terminal
colors; changing the theme updates the transcript in place. There is no separate
conversation theme picker or preset catalog.

Every action in the body (links, files, clipboard, approvals, attachments,
previews, citations and project reads) goes through `AgentConversationActions`,
which checks each target against the retained snapshot and the session's own
project before anything opens.

Tool details retain input and output separately, with running, completed, failed,
denied and interrupted states when supplied by the provider. Completed turns fold
their commentary and tools into a **Worked for…** disclosure, leaving the final
answer visible. Durations use persisted server timestamps, so reconnecting does
not restart the clock. Older snapshots without timing retain ordinary activity
disclosures. Pending approvals never fold into a completed-work disclosure.

Responses and user messages have copy actions. Long user messages collapse with
**Show more** / **Show less**. File links open the project's editor at the linked
line and column, with a context menu of file actions; links to other conversations
render as chips that open them; ordinary web and mail links use macOS link handling.

Structured provider questionnaires and other interactive extensions are reported
as unsupported; ask the agent to use ordinary chat for questions.

The server keeps a bounded transcript snapshot (up to 512 recent rows and about
512 KiB of text, with pending approvals retained). Older output can be trimmed;
this is not a full provider-history browser. The provider's own conversation ID
is stored separately for resume. The conversation exposes the whole retained
snapshot through a virtualized scroll surface; it does not discard retained rows
to limit mounted view counts. Pending approvals remain accessible in that history.

## Provider reference

The original Swift provider-adapter implementation follows T3 Code
(<https://github.com/pingdotgg/t3code>) at revision `6fc9144a60c4a5f45089316ddd5f7371bafd3bf2`. Key references:

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
- Provider discovery protocols supply model names and reasoning capabilities;
  T3 Code's model manifest remains a behavioral reference rather than a picker catalog.

T3 Code's server is TypeScript and its Claude adapter uses the Agent SDK. Tab adapts
these behaviors into Swift and drives the installed CLIs over pipes. Claude
SDK fixture operations such as `query.open` and `permission.request` are not
literal CLI wire messages; the Swift adapter uses Claude's bidirectional
`control_request` / `control_response` envelopes instead. Codex runs through
`codex app-server`.

T3 Code's MIT notice is retained in `THIRD_PARTY_NOTICES.md`.
Provider SDKs and executables are not vendored.

## Native transcript inventory

The table below records what the native transcript implements and what it still
lacks compared with the T3 Code conversation components it was ported from.
Component paths are relative to `apps/web/src/components/`.

### Earlier native rendering follow-up

Compared the conversation components against T3 Code in this iteration:

- `TimelineWorkGroupRows.tsx`: the live timer is a timeline row before work,
  with a bottom divider; it does not belong above the composer. Native rendering
  now uses persisted turn start times and updates only mounted timers.
- `WorkLog.tsx` and `TimelineWorkEntryRow.tsx`: icon/action/disclosure rows expose
  tool details directly. Native rows no longer add a second group disclosure or
  duplicate the tool name and successful status in every action label.
- Completed work retains its final answer outside the disclosure and now has a
  trailing disclosure indicator and divider. Bounded expanded work scrolling
  remains intentional: upstream also virtualizes expanded work groups.
- `TimelineUserMessageRow.tsx` and `TimelineAssistantRows.tsx`: attachment cards,
  contextual chips, response footer visibility, and rich media still differ.
  User bubbles now use the upstream 80% limit and retain full Markdown when
  clipped; the final answer footer appears on hover or keyboard focus. Collapsed
  messages use the upstream 28-pixel fade and “Show full message” action. Code
  blocks default to wrapped text, retaining explicit per-block choices through
  virtualization.

### Parity inventory

| Area | Native implementation | Remaining source behavior / reference |
| --- | --- | --- |
| Streaming and resume | Stable partial-response text views; server-owned conversations and provider resume IDs; startup interruption; persisted turn timing | T3 Code's thread lineage, fork/revert and checkpoint workflows are not implemented (`chat/ThreadLineageWorkflowRow.tsx`, `chat/TimelineAssistantRows.tsx`). |
| Work logs | Individually virtualized tool rows in the main conversation, with 14px labels, 16px pinned Lucide category icons, source insets, keyboard disclosure and conditional chevrons; expandable input/output; shell inspectors keep highlighted source above independently scrolling output (320px limit), show only nonzero exit codes, and use browser-verified 13px/21.125px typography with 6px section gaps; pinned light/dark ANSI palettes, 256/RGB colors, bold/dim/italic/underline/strike/inverse styles and badge contrast, cursor/erase/progress replay in a bounded 64-line live window; colored changes; file/web links; completed-work folding with pinned 14px disclosure chevrons and a 4px text gap; expanded history projects into the main virtualized timeline with child interaction state retained across folding | Source syntax colors and grouped-row geometry remain under review. Terminal normalization and truncation now match upstream byte-for-byte for long plain/styled output, dense style runs, Unicode and cursor edits at the limit; native badges use the measured inline font box and corrected baseline. Inspector identity follows T3 Code's native-tool classification independently of semantic icon categories, including normalized Claude names and generic fallback for unknown/MCP tools. Codex dynamic tools preserve namespace-qualified names and mixed contentItems, with MCP structured-output precedence and error/result context. Generic tool panels now retain ordered argument names, null/empty values and structured results without generic Input/Output headings. Structured/summarized arguments now scroll independently at 320px with their position retained across row eviction; completed empty results show the italic No output label. Structured JSON arguments use browser-verified source light/dark token colors, including escapes and distinct null/boolean scopes. Recognized js/node_repl.js/cua_repl.js calls place code below its label in an independent 320px scroll block, preserving surrounding arguments and scroll state. REPL syntax currently uses the native TypeScript tokenizer; exact source grammar/colors, other syntax grammars remain under review. Claude streamed/assembled and Codex dynamic-tool arguments retain their original provider JSON order through persistence; JavaScript numeric-key ordering still applies in the inspector. Unmodified structured results preserve provider key order, including Codex MCP error/result wrappers, and scalar JSON results remain visible. Image extraction replaces only selected image blocks in the wire JSON; surrounding fields retain their order. Shadowed duplicate values are cleared without changing first-key/last-value semantics, and images beyond the eight-preview limit are redacted too. Dynamic tool raster results now store up to eight 10 MiB images outside transcript JSON, retain message-owned retrieval across restart, and render above output with 480px width/256px height caps and native previews. Tool-image loading uses a blank framed slot; failures show the centered warning glyph and Image unavailable label without attachment retry text. Animation and media action styling still need full source comparison. File-change inspectors now retain provider patches and operations, show workspace-labelled paths and optional counts, and open immutable recorded diffs; failure text and operation rows follow the typed inspector layout. Diff-window presentation itself still needs comparison against T3 Code. Explicit file-search records render a pattern, workspace-labelled paths, optional line/column positions and whitespace-preserving previews; current Claude/Codex adapters do not emit this type, so Grep/Glob remain generic tools. Typed web-search inspectors retain Codex action patterns and Claude result metadata, with query text, title links, external-link glyphs, hover underlines and snippets; end-to-end live provider verification remains pending. Tool timestamps use source-sized text and appear on disclosure hover/header focus; grouped rows use 24px headers versus 28px standalone rows. Failed/denied and nonzero-exit tools preserve muted summary labels and tint category icons using captured light/dark source colors; interrupted rows remain neutral. Nested-control focus and completed-fold timestamps still need comparison. Subagent thread navigation, richer checkpoint summaries and provider-specific interactive tools need additional protocol data (`chat/TimelineWorkEntryRow.tsx`, `chat/TimelineWorkGroupRows.tsx`). |
| Approval and composer | Native model/effort/access menus, inline permission actions, Stop, growing text input, @ file/thread suggestions, / native actions and discovered skills, attachment picker/drop/paste, scroll following and scroll-to-end | Structured questionnaires, provider-specific goal/feedback/usage commands, machine/PR mentions and queued/steered messages are not implemented. |
| Markdown prose | Shared user/assistant interactive rendering (user HTML disabled), browser-measured 14px/22.75px prose and heading leading, collapsed block spacing, headings, paragraphs, inline emphasis/code, nested list markers, tasks, quotes, links, GitHub alert containers, nested expandable details with retained state, and message-local heading links with Unicode/duplicate slugs and reveal-on-navigation, and document-wide full/collapsed/shortcut reference links (including streamed definitions), and numbered footnotes with repeated back-links and rich note bodies; CR/LF/CRLF block recognition preserves original in-node line endings and replaces NULs as in T3 Code; empty/tab-separated ATX headings, closing markers, multiline single-marker Setext headings and four-space code boundaries match browser fixtures; ordered-list runs share browser-sized widest-counter gutters across siblings and nested lists, retained across interactive code/table sections and streaming counter growth, with tabular-digit markers aligned before the text; ordered lists count from the first item, preserve counts across loose-item spacing, restart on delimiter changes, and use matching-ancestor marker styles; unordered lists use browser-measured geometric disc/circle/square markers and 20px nested gutters without changing copyable text; task markers use native 13px checkbox drawing with pinned disabled light/dark colors and measured text gaps, suppressing invisible fallback-glyph metrics while preserving selectable checkbox text; non-one ordered starts require separation before interrupting paragraph text; neutral light/dark prose, heading, link, inline-code, quote-rule and table-rule colors follow captured source tokens, and horizontal rules use full-width native one-pixel sections; fixed-height Markdown line boxes use browser-measured centered-leading baselines, fractional section heights and 1/64-point CSS spacing; inline code uses T3 Code's SF Mono face and inherits 85% font sizing/weight and draws rounded backgrounds per wrapped line using browser-rounded font bounds and fractional vertical padding; rendered inline whitespace collapses like CSS while explicit backslash/two-space hard breaks remain visible and user messages preserve ordinary line breaks; link labels retain nested emphasis, strike and code with UTF-8/CRLF-safe source recovery | External link prefixes reserve the source 14px icon box and font-relative margins without adding characters to selection/copy; provider artwork and lazy remote favicons now use source host classification, shared loading, sticky globe fallbacks and selection-preserving redraw; plain-link protocol prefixes suppress internal word/hyphen breaks while retaining individual text glyphs, overflow narrower text fragments and contribute to table minimum widths; adjacent links retain separate favicon boxes even when destinations match; remaining long-label wrapping and shaping still need comparison. Inline-code boundary glyphs now reserve browser-sized horizontal borders/padding while preserving text and selection, including linked code and table sizing; prose, hanging-indent list items and table cells now reserve and paint cloned padding on wrapped fragments, excludes collapsed trailing spaces from their backgrounds, and bounds width probes for long spans; broader wrap cases, browser pretty-wrapping and table row/column allocation still need comparison. List identity, parent identity, original delimiter, start/end counters and ancestor marker families now survive parsing and rich-section partitioning; loose paragraphs and outer margins use browser-measured spacing, including ordered task gutters and fenced blank-line exclusions. A sanitized inline HTML subset (formatting, links, images, anchors, `dir`/`bdo`, standalone block elements) and streaming completion of unclosed inline markers in the last block are native; full CommonMark/GFM parsing edge cases and arbitrary HTML block semantics remain (`ChatMarkdown.tsx`, `chat/MarkdownDetails.tsx`, `chat/markdownFragments.ts`). |
| Code | Tab's native incremental tokenizer with grammars for more than 70 languages (Swift, Rust, C/C++/Objective-C, Go, Python, Ruby, JavaScript/TypeScript, JSX/TSX, Java, Kotlin, C#, F#, PHP, Scala, Dart, Lua, Perl, R, Julia, Haskell, Elixir, Erlang, Clojure, Lisp, Zig, Nim, Groovy, PowerShell, Vim, shells, SQL, HTML/XML/CSS, JSON/YAML/TOML/INI, Markdown, Dockerfile, Makefile, CMake, Nix, Terraform, GraphQL, Protobuf, nginx, LaTeX, diff, log, http, assembly, shaders and more) resolved from the fence info string through shiki-compatible aliases; browser-verified default 13px code with 17.875px leading and source padding, Pierre/source file icons with language aliases and icon-only language headings, compact pinned Lucide copy/check/wrap/run controls, exact-source copy with timed feedback, wrap toggle and horizontal scrolling; completed, closed eligible shell fences can run in a project terminal | Heredocs, regex literals and string interpolation are not tokenized; application wrap preference (`chat/MarkdownCodeBlock.tsx`). Fenced code now follows browser-verified opener/closer indentation and marker rules, info-string restrictions, body de-indentation with tab stops, and empty/unfinished block newline behavior. Nested fenced code and tables retain native widgets in quotes, rich list items, and details; full list-block parsing remains under review. |
| Tables | One native TextKit table supports continuous cross-cell selection and links, retained selection through resize/streaming, word-based column minimums and horizontal overflow, 14px text, flush outer columns, row-only separators, viewport alpha fades that follow hidden content up to 24px per edge and clear on viewport keyboard focus, and an icon copy menu with 1.2s feedback for Markdown/CSV; CSV matches rendered source cells, JavaScript whitespace normalization and conditional quoting; Markdown export preserves distinct adjacent links, resolves references, pads missing cells and serializes parsed inline formatting, links, entities, code fences and escaped pipes against browser fixtures; browser fixtures cover short separators, pipe-free body rows, block interruptions, list precedence and escaped pipes inside code | Browser-measured fractional header/body padding and shared-row rules now avoid TextKit rounding drift; the 384px cell cap includes padding, and copy controls retain their full hit area in the conversation gutter while respecting viewport clipping. Extreme-width browser column allocation, remaining image/HTML and adjacent emphasis-span Markdown export cases, copy/check morph animation, and table-specific accessibility navigation still need comparison (`chat/MarkdownTable.tsx`). |
| Links | HTTP/HTTPS/mailto; file paths and line navigation into the project editor; file links show a hover tooltip with path, kind, size and modified date (fetched once per path per conversation) and missing files render muted and struck through; bare GitHub pull-request links (github.com and the project origin's host) get a native card with state, title, repository, author and age that opens the link; assistant citation links and composer chips scroll to the quoted message and highlight the quote for 1.5s with a fade; clicking a file link with a `:line:column` or `#L10C3` suffix opens the editor at that position; right-clicking an assistant file link offers Open in Editor, Open at Line N, Preview, Reveal in Finder (local projects), Copy Path, Copy Relative Path and Open in Browser (local HTML files), and a web link offers Open in Browser (a Tab browser pane) and Copy Link; failed link actions show in the composer's error line. Thread links (`tab-thread://<project>/<session>` or `tab-thread://<session>`, which the composer's `@` thread mention sends as `[@Title](…)`) render as a chip with the conversation icon and title (a known title of the project's conversations, else the link label, else the session id prefix) that opens the conversation | Avatars are initials (no remote avatar fetch); file links inside tables and footnotes get no tooltip or context menu; the web renderer's app-relative `/<environment>/<thread>` links are not recognized. |
| Copy and selection | Selectable prose/code, response/user copy, exact code copy, table export; a floating Cite/Copy toolbar after a mouse selection in an assistant message (hidden on scroll, Escape, focus loss or an empty selection) and Cite/Copy/Copy as Markdown context items; Shift/Command-click adds selections in other sections of the message; Copy (and Command-C) writes plain text, HTML and a `application/x-tab-context-fragment+json` fragment that pastes into the same conversation's composer as a quotation; Copy as Markdown recovers the selected Markdown source, including emphasis and links. Selections address the message's rendered plain text (text views in reading order, joined by a blank line). | Drag-selection that continues across sections in one gesture and the source toolbar's exact styling (`chat/AssistantSelectionToolbar.tsx`, `apps/web/src/markdown-clipboard.ts`). |
| Math and diagrams | Native LaTeX typesetting on STIX Two Math (Core Text, OpenType MATH table): inline `$…$`/`\(…\)` as baseline-aligned attachments, display `$$…$$`/`\[…\]`/```math blocks centered with horizontal overflow scrolling and Copy LaTeX; invalid commands render in the error color without aborting the expression. Native Mermaid rendering for flowchart/graph, stateDiagram, sequenceDiagram, classDiagram, pie, gantt and xychart with a Diagram/Source toggle (retained across virtualization), Copy and Expand into the zoomable media window; invalid sources show the code with a line-numbered error | Infix `\over`/`\choose`, macros, `erDiagram`, `mindmap`, `timeline` and other Mermaid kinds show their source; tall inline fractions can touch adjacent lines because line height stays fixed. |
| Media and embedded apps | Assistant Markdown images and bare image/video/audio links (remote, `data:` and project files through the owning server) as bounded tiles and collages with inline thumbnails, a lazy per-conversation LRU loader, message galleries and isolated video/audio playback; file/image attachment transport, durable message-scoped payload retrieval, draft thumbnails, user image collages with loading/retry and zoomable galleries, native GIF playback in conversation tiles and expanded previews (up to 16,777,216 aggregate frame pixels), window-attached expanded media overlay with 75% backdrop, source-sized controls/caption/failure frame, desktop/narrow layout snapshots and focus restoration, cyclic expanded-gallery navigation, browser-verified fit/zoom geometry without upscaling, click/wheel/keyboard zoom (1–8×), anchored zoom, drag and arrow-key panning with gallery-navigation precedence and resize refitting, image context menus with Shift-F10 access, original-byte saves and full-resolution oriented PNG copies, file cards/downloads and PDF/Markdown/text previews, Claude native image/PDF input and Codex native image input | Inline video/audio players (media opens in the isolated media window), animated WebP/APNG and GIFs above the native decoder allocation limit (currently static thumbnails), media-reference path/URL actions, exact tooltip/toast styling, expanded-viewer transitions and screenshot accessibility-details/original-link controls, specialized Office/font/delimited-file previews (`chat/ChatMarkdownMedia.tsx`, `chat/ExpandedImageDialog.tsx`). Published HTML (`html_render`) and MCP app documents render as a native card (title, size, server/tool) directly below the tool row's header, visible without expanding the tool call, with Open preview in an isolated sandboxed preview window showing only the supplied bytes, Download and Copy source; MCP tool/resource round-trips from inside the document are not available. Codex `::artifact-template` directives render as a native card whose Use template button appends the use prompt to the composer without sending. |
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

The native transcript audit on October 30, 2026 exercised live Claude streaming and Auto
web/read tools, expanded input/output logs, code copy/wrap, CSV table copying,
project file navigation and narrow layouts. Screenshots and the incremental
accessibility capture are under `build/validation/agent-ui/` and
`build/validation/live-stream-accessibility.log`. Completed approvals were absent
from the visible conversation. The original preview's provider conversation ID
and all 27 retained items survived relaunch. The 5,000-entry virtualization test
mounted 12 rows, retained 14 views and performed 14 initial measurements.
Live Codex validation remains blocked by the installed CLI hanging on launch.

Conversation attachment cards and changed-file leaves use the pinned Pierre/source icon catalog at 16px and 14px respectively, refreshed on theme changes. User attachment cards follow T3 Code's filename-only resolution; the shared resolver also supports T3 Code's exact MIME fallback for unknown filenames where callers request it.
