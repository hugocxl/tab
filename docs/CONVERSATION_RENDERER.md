# Tab conversation renderer port

The Agents tab uses the actual upstream conversation components pinned at
`e5909e53c32a9d5b51caf6352d1f17fd73e86db7`, bundled in a nonpersistent WKWebView.
The user approved this JavaScript integration and subsequently requested native
macOS fonts wherever possible and reuse of the app's existing themes. Scope is the conversation body and its
actions;
the native composer and application shell are not redesigned.

All scoped source comparisons and action checks below are verified. Final
`scripts/validate.sh` completed successfully: 1,309 tests across six modules,
31 skipped and zero failures. The app module contains 664 tests, including
the two native conversation-theme tests, with 28 skipped and zero failures.
Native compilation, bundling and code-signature verification also passed.

## Ownership and boundaries

- The renderer owns message layout, working timers, folded work histories, typed inspectors,
  Markdown, code, math, diagrams, media dialogs, selection, search and overlays.
- Swift owns providers, persistence, the existing composer, approvals, project
  services, navigation and the existing app theme. A versioned snapshot/action
  bridge joins these parts. Native `AppTheme`, `SyntaxColors` and `TerminalPalette`
  supply conversation semantic, syntax and ANSI colors; no theme picker is added.
- Provider JSON, stable message identities, optional observed lifecycle metadata
  and monotonic snapshot revisions preserve streaming and interaction state.
  Missing historical timestamps and provider identities remain unknown.
- Source parent canvas/follow behavior receives the real native composer geometry.
  Transparent composition and portal hit regions let source dialogs/menus occupy
  the pane without duplicating the composer in HTML.
- A renderer failure restores the native transcript at its semantic reading
  anchor. Disposed/failed pages cannot change modal state, focus, scroll or anchors.
- File/media actions remain bound to the first authoritative session project and
  server, including after the pane moves. Initial Home remapping remains supported.
- Renderer scripts, styles, fonts, syntax grammars, WASM and lazy chunks are local.
  Referenced HTTP(S) images/media/favicons may load; normal browser CORS still
  governs byte access for copy/save. No upstream service or authentication runs.

## Verified acceptance

| Area | Evidence |
| --- | --- |
| Source fidelity | Eight controlled no-palette compatibility timeline screenshots have zero differing RGBA pixels: 360/800 widths, light/dark, collapsed/expanded histories. Text, structure and geometry match; only generated Base UI IDs are normalized. |
| Existing app themes | Three browser checks verify actual prose/headings, links, cards/menu/borders, Swift/JSON tokens and ANSI output against the native palette. Same-mode changes preserve DOM identity, selected text and expanded inspectors; explicit authored RGB remains intact. Two native theme tests also pass, including actual WK same-mode palette/syntax updates without conversation reload. |
| Markdown | Twenty corpus cases across four width/theme configurations cover GFM tables/lists/footnotes, HTML anchors/details/bidirectional text, literal user HTML and incomplete streaming syntax. No comparison failures. |
| Code/math/diagrams | Actual source engines load in offline WKWebView. Five source action checks cover wrap, exact shell command dispatch to a mock host, diagram/source switching, expansion/Escape and capability gating. |
| Tools/provider metadata | Eleven source projection checks cover typed inspectors, exact provider JSON, observed reasoning/compaction/plans/todos/errors, interruption, timing, scoped attachments and bounded/clipped payloads. Native provider regressions cover replacement/deduplication and backward-compatible transport. |
| Plans and templates | Seven source plan checks cover typed todos, copy/download, nested workspace Save, visible failures and read-only exclusion. Five template checks cover exact source prompt generation, append/deduplication, concurrent typing and unavailable actions. Template clicks never send. |
| File links and PRs | Source metadata tooltips pass two checks; PR cards pass five for HTTPS/SSH identity, late metadata, scoped requests and failure fallback. Native file/range/write, saved-session navigation and project-scope regressions verify supporting services. |
| Selection/citations | Source code/table Markdown/CSV and cross-section plain/HTML copy, actual Cite and folded-source navigation pass. Native clipboard preserves text/custom MIME data and bounded chunked PNG transfers above 10 MiB. |
| Media | Actual source attachment/workspace image copy/save and native WKDownload are exercised. Native ranged media verifies metadata and seeking; remote fixtures verify exact image/video bytes and visible CORS refusal. |
| Supplied HTML/MCP | Actual source document/bootstrap helpers and opaque sandboxes are retained. Native tests prove owned document execution, inert ordinary HTML, ownership invalidation, declared nested HTTP frame execution, undeclared/direct remote frame rejection and no subframe native bridge. |
| Search | Seven checks exercise the unchanged source Find bar/hook/highlights, next/previous, folded responses, streaming invalidation, offline retained history and Escape/focus. Four startup checks prove Find queues before the first snapshot mounts; native menu/shortcut regression verifies the real bar. |
| Streaming/virtualization | A 1,005-item source history mounts 18 rows; twenty updates retain mounted identities, selection and expanded ANSI output. Source follow checks preserve the reader's offset while streaming and follow an accepted turn. Real-daemon WK integration proves two partial responses update the same laid-out source node before the provider may emit its final response. |
| Lifecycle/accessibility | Source keyboard actions, reduced motion, narrow layouts, modal focus/send interlock, bounded evaluation, cancellation, reload/disposal and semantic fallback are covered. No full screen-reader audit is claimed. |
| Reproducibility | Independent pinned checkout/frozen dependency bootstrap verified. Current clean extraction rebuild matches all 343 published asset hashes exactly, including the current theme integration. Extraction and specialized-font policy remain pinned. |

Source QA artifacts are under `vendor/ConversationRenderer/.work/qa/`, including
`full-source-differential/pixels.json`, `corpus/comparison.json`, `thread-find`,
`code-actions`, `large-history`, `parent-follow`, `inline-pr`, `native-palette` and
`clean-rebuild.json`. Reproducible fixture scripts are checked in under
`vendor/ConversationRenderer/tests/`; generated reports are ignored development output.

The 1,005-item frame-inclusive update mean/p95 was 31.97/33.70 ms. This includes
two animation frames and is not a React CPU-time measurement. The desktop was
locked during native gesture auditing: source browser fixtures cover gestures,
while actual WK/native tests cover layout, data, actions and lifecycle. These are
not claims of automated on-screen native gesture or VoiceOver validation.

## Existing app colors, fonts and assets

The user explicitly chose existing app colors and native fonts over pinned-source
color/font identity. Semantic CSS variables use the current native palette;
source syntax tokenization and grammars use a CSS-variable theme, and ANSI spans
use the existing terminal palette. Same-appearance theme changes repaint cached
source tokens without replacing conversation nodes. HTML/MCP document theme
messages use the same semantic values. Explicit content colors and true-color
terminal escapes remain unchanged.

The unused source theme catalog is excluded at its loader boundary. Only the two
source-requested compatibility palette names remain for snapshots without a
native palette (in both existing highlighter representations). There is no
independently maintained theme catalog, settings UI or separately
selected conversation theme.

Normal chat text uses the source renderer’s native `-apple-system` stack; code uses its native
monospace/SF Mono/Menlo stack. Bundled Inter is removed. KaTeX retains its exact
specialized equation glyphs and metrics in only 20 WOFF2 files, totaling
259,792 bytes. Duplicate WOFF/TTF formats are unnecessary for macOS 14+ WebKit.

Unused office and PDF viewers were entering the bundle through sibling exports
of shared source modules. The build now extracts the required read-only snippet
and HTML-document exports unchanged, rather than importing those unused viewers.
Native attachment open/download behavior is retained. No referenced asset is
simply deleted after bundling.

The final renderer has **343 assets totaling 29,081,131 bytes**, down from
approximately 94.5 MB / 844 assets. Theme-catalog pruning alone removed 147 assets
and 1,899,629 bytes from the preceding 490-asset build.
Only the 20 equation fonts remain; there are no bundled general-purpose fonts.
`manifest.json` records source/generated hashes for each extraction and the
original/transformed KaTeX CSS, version, face count and format policy. It also
records the user-authorized native color policy and compatibility theme names.
Source and
dependency licenses remain bundled.

## Existing native service limits

This iteration does not implement a new orchestration backend. Source controls
follow actual native capabilities and observations:

- Search covers retained user/assistant/plan content. Historical paging beyond
  the native snapshot is unavailable; search does not claim to load it.
- Provider-session fork and conversation/checkpoint restoration APIs are absent.
  Source fork/edit-from-here controls use their normal capability gates.
- Embedded-app sending requires upstream queued-turn semantics. Native sends
  currently accept idle/failed sessions, so the source app protocol explicitly
  refuses this operation. Missing MCP RPC/auth/resource operations likewise
  return explicit failures; supplied owned documents can still render.
- Attempt/node graphs, child-session identities and structured-question response
  APIs are not invented. Available tool payloads remain readable; unsupported
  provider control requests keep their explicit notice.
- New range, PR-preview and parent-directory-write behavior is feature negotiated.
  Older running daemons retain defined fallbacks or visible unsupported errors.
  Updating the preview daemon must preserve running sessions: never force a
  restart merely to activate these APIs.

## Build and verification

```sh
node vendor/ConversationRenderer/build.mjs
node vendor/ConversationRenderer/verify.mjs --check-inputs
scripts/validate.sh
```

The emitted artifact and its current source inputs pass strict verification.
The final unfiltered `scripts/validate.sh` passed, including native compilation,
all six test modules and bundle/signature verification. The app bundles the
renderer; no development server is needed. Native
fallback tests retain their own coverage, while the real-daemon streaming test
asserts the active source DOM rather than hidden native text views.

The preview was reopened from the latest signed app with this renderer active.
An idle-only server shutdown refused to stop running terminals, so the existing
daemon and session host were preserved. Supporting server features remain
capability negotiated until a safe restart; renderer activation does not require
interrupting those sessions.

## Product namespace and startup

Tab maintains the `ConversationRenderer` integration and its platform adapters.
Third-party copyright, source revision and required compatibility names remain
centralized in the provenance record and notices. New citations, clipboard
context fragments and embedded-app output use the Tab namespace; retained legacy
citation and embedded-app metadata remain readable without rewriting provider
JSON. Renaming does not transfer the underlying third-party ownership.

The host treats transport `ready` separately from snapshot `rendered`: activation
waits until a themed React commit acknowledges the current conversation. Loading
keeps the native themed surface, and only an actual renderer failure reveals the
native transcript fallback. The final unfiltered validation passed after the review
and startup fixes, including the latest main changes: 1,323 tests, 31 skipped,
zero failures, plus bundle/signature
verification. Renderer assets and build-input hashes also pass strict verification.

The pre-commit review removed four unused protocol fields and redundant checkpoint
diff work, bounded typed metadata without dropping tool rows, moved tool-image disk
writes off the shared session queue with ordered bounded buffering, fixed attachment
cache identity collisions, and corrected fallback theme/count handling. The reviewed changes are included in the 0.14.0 changelog.
