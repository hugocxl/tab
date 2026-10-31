# Tab conversation renderer

This directory builds the actual upstream conversation components at the revision
in `PINNED_REVISION`. The native composer, pane chrome, provider processes and
filesystem access stay in Swift. The renderer uses the upstream Markdown,
conversation rows, virtualized timeline, code highlighting, math, diagrams and
media dialog. Application services are adapted through `src/platform`; rendering
components are extracted from the pinned Git revision, with audited namespace and
compatibility transforms recorded in `provenance.json`.

Build prerequisites are Git, Node 26 and pnpm 12.14.0. A clean build fetches the
pinned source into ignored `.work/checkout` and installs its frozen dependency
lock. `CONVERSATION_SOURCE=/path/to/checkout` can reuse an existing dependency installation;
tracked package sources must match the pinned revision. Without `CONVERSATION_SOURCE`, a clean build fetches an isolated checkout. `prepare.mjs` extracts
tracked source with `git archive`, so local upstream fixture files never enter
the renderer.

```sh
node vendor/ConversationRenderer/build.mjs
node vendor/ConversationRenderer/verify.mjs
```

The default output is `Sources/TabApp/Resources/ConversationRenderer`. `CONVERSATION_OUTPUT=.work/full`
keeps an integration build isolated during native validation. `CONVERSATION_SMOKE=1` selects
the actual upstream ChatMarkdown smoke entry instead of the complete timeline.
`CONVERSATION_SOURCEMAPS=1` emits optional debug maps; they are not needed at runtime.

Every emitted asset is local and hashed in `manifest.json`, together with the
upstream revision and lock hash. The bundle contains the source renderer’s MIT license and the
upstream web dependency license manifest, including font, math, diagram and
syntax-highlighter dependencies. Runtime rendering does not load JavaScript,
fonts or grammar chunks from a CDN. Owned attachments and media use the native
`tab-conversation:` scheme. Scripts remain restricted to the renderer's origin;
untrusted previews retain the upstream frame sandbox and cannot call the native
bridge.

`src/bridge.ts` defines the versioned snapshot and request/reply contract. Native
capabilities control actions that require an application service. The source
renderer owns layout, scrolling, fold state, selection and media display. A
render error or missing full-timeline feature keeps the existing native fallback
available while integration is being validated.

The following commands regenerate upstream browser oracles and compare the
bundled Markdown renderer across narrow/wide, light/dark fixtures. Generated
Base UI identifiers are normalized; explicit authored anchor identifiers, text,
structure and measured geometry are compared directly.

```sh
node vendor/ConversationRenderer/tests/write-source-oracle.mjs
pnpm --dir "$CONVERSATION_SOURCE/apps/web" exec vp test run --config TabSourceParity.vite.config.ts --project browser src/components/chat/TabSourceCorpus.browser.test.tsx --update
CONVERSATION_SMOKE=1 CONVERSATION_OUTPUT=.work/parity node vendor/ConversationRenderer/build.mjs
node vendor/ConversationRenderer/tests/compare-corpus.mjs
CONVERSATION_BUNDLE=.work/full node vendor/ConversationRenderer/tests/smoke.mjs
CONVERSATION_BUNDLE=.work/full node vendor/ConversationRenderer/tests/settings-toggle.mjs
```

The corpus covers GFM structures, rich lists, references and footnotes, HTML
anchors and literal user HTML, details, bidirectional text, actual KaTeX and
Mermaid output, syntax highlighting and incomplete streaming syntax. It is a
regression corpus, not a claim that every provider capability or application
integration is complete. Full-timeline interactions and native bridge ownership
have separate tests.

A clean bootstrap can be validated without touching the working extraction:

```sh
clean_renderer=$(mktemp -d /tmp/tab-renderer-clean.XXXXXX)
rsync -a --exclude=.work vendor/ConversationRenderer/ "$clean_renderer/ConversationRenderer/"
env -u CONVERSATION_SOURCE CONVERSATION_OUTPUT=.work/output node "$clean_renderer/ConversationRenderer/build.mjs"
CONVERSATION_BUNDLE=.work/output node "$clean_renderer/ConversationRenderer/verify.mjs"
```

Full-timeline rendering has a separate upstream oracle. Its cases use unique
thread, message and turn identities so source-persisted fold state cannot leak
between viewport/appearance cases. It compares collapsed and expanded source
histories, row text/structure and measured geometry at 360/800 pixels in both
appearances.

```sh
node vendor/ConversationRenderer/tests/write-full-timeline-oracle.mjs
pnpm --dir "$CONVERSATION_SOURCE/apps/web" exec vp test run --project browser src/components/chat/TabFullTimelineSource.browser.test.tsx --update
CONVERSATION_BUNDLE=.work/parent node vendor/ConversationRenderer/tests/compare-full-timeline.mjs
CONVERSATION_BUNDLE=.work/parent node vendor/ConversationRenderer/tests/large-history.mjs
```

Supplied MCP app documents retain the actual upstream `McpAppFrame`, protocol
host and opaque-origin iframe sandbox. The platform adapter never constructs an
upstream connection/authentication runtime. Tool calls, resource reads, tool
metadata and model-context updates require explicit native per-operation
capabilities (`mcpApps.callTool`, `mcpApps.readResource`, `mcpApps.toolInfo`,
`mcpApps.updateModelContext`). Current providers do not expose those operations;
the actual source protocol returns explicit failures. This is a rendering port,
not an MCP backend. Owned document loading has a separate native acceptance gate
for the retained resource's render intent and source CSP; generic HTML does not
gain script privileges from an unverified caller-supplied intent.

```sh
CONVERSATION_QA_ENTRY=mcp-services node vendor/ConversationRenderer/build.mjs
node vendor/ConversationRenderer/tests/mcp-services.mjs
```

The MCP fixture serves a supplied document using the exact pinned CSP/theme/cookie
bootstrap helpers and HTTP sandbox header. It verifies visible app content,
opaque-origin isolation, real source protocol refusals and no discovery,
authentication, RPC or external network requests. It does not establish native
provider operation support.

The renderer CSP keeps executable code, external styles and fonts local. Source
message content may load HTTP(S) images/video and link favicons, and source media
actions may fetch those URLs. Browser CORS still applies: a displayable image can
refuse byte access for copy/save, in which case the actual source error UI stays
visible. `tests/remote-media.mjs` exercises this with controlled HTTP media and an
intercepted HTTPS favicon, including exact PNG clipboard and MP4 save bytes.

Native supplied MCP documents use `TabConversation.prepareMcpDocument` to reuse
the pinned reference normalization and document CSP/theme/cookie transformations.
The host validates ownership, retained reference/version and source size limit
before calling it, then registers a distinct scoped document response. It does
not grant script privileges to the raw attachment or renderer page. Blob/data
frames inherit the renderer policy and are therefore unsuitable for executable
supplied apps under the unchanged local-script policy.

`source-content-routes.mjs` supplies identical controlled favicon bytes to the
upstream test browser and bundled corpus browser. Referenced content remains
enabled; allowed content requests are recorded separately from unexpected remote
code or service requests. Full-timeline screenshot fixtures use the actual source
appearance setting and wait for hover transitions to settle.

```sh
CONVERSATION_BUNDLE=.work/services node vendor/ConversationRenderer/tests/compare-full-timeline.mjs
node vendor/ConversationRenderer/tests/compare-timeline-pixels.mjs
```

The pixel check decodes all eight narrow/wide, light/dark, collapsed/expanded PNG
pairs and compares every RGBA channel without masks or color tolerances.

The macOS integration uses the source native system font stacks for ordinary
text and code. It does not bundle Inter. Mathematical notation retains the
20 KaTeX WOFF2 faces (259,792 bytes) because their metrics are part of the math
layout engine; the build removes only the redundant WOFF/TTF source alternatives.
The manifest records this font policy and both CSS hashes.

Pinned export extraction keeps the actual read-only source preview and HTML
renderer without bundling unused office/PDF viewer siblings. The same provenance
mechanism extracts the pure source search-selection helpers without importing a
SQLite orchestration service. Each extraction records original and generated
hashes. The renderer has no bundled general-purpose fonts.

Conversation Find uses the actual source bar, state and highlighting over retained
messages/plans. Source parsing and counting are unchanged; its per-item parse
cache is byte bounded without limiting searchable text. An initial native Find
request queues until the first conversation parent mounts. Search does not invent
remote history paging or unavailable provider question-response services.

Conversation colors come from the app's existing `AppTheme`, `SyntaxColors` and
`TerminalPalette`, including same-appearance theme changes. This is the user's
explicit color exception to the pinned-source visual oracle; source layout,
parsing, grammars and controls remain unchanged. Native semantic CSS variables
also feed the actual HTML/MCP document theme messages. Explicit authored content
colors and true-color terminal escapes remain intact. There is no renderer theme
picker or preset catalog. Only the two pinned compatibility palettes requested
by source code remain for no-palette fixtures, with the original highlighter
backends; native snapshots use a CSS-variable syntax theme instead. The manifest
records this policy.

The final app-theme artifact contains **343 assets / 29,081,131 bytes**. Excluding
unused theme presets removed 147 assets and 1,899,629 bytes from the preceding
build. An independent pinned-checkout rebuild matches all 343 emitted hashes;
strict `verify.mjs --check-inputs` passes for the published artifact. The eight
no-palette source timeline screenshots still compare pixel-for-pixel. Three
`tests/native-palette.mjs` checks additionally verify actual rendered prose,
headings, links, cards/menu/borders, Swift/JSON syntax and ANSI colors, with
same-mode selection/node/expanded-state retention and authored RGB preservation.
Final `scripts/validate.sh` passed: 1,309 tests across six modules, 31 skipped
and zero failures. The app module includes 664 tests (28 skipped), including
two passing native theme tests for shared palette serialization and actual WK
same-mode palette/syntax updates without conversation reload. Native compilation,
bundling and code-signature verification also passed.

The integration and resources are named `ConversationRenderer`. Required external
package names and legacy persisted metadata are isolated in `provenance.json` and
the build compatibility adapter. The original license and dependency notices are
retained as `UPSTREAM-LICENSE.txt` and `third-party-licenses.json`; renaming does
not transfer third-party copyright. Every build re-extracts a fresh pinned Git
archive, including its license plugin/configuration and notice inputs.

Transport `ready` only permits the host to send data. The source parent emits
`rendered` after the first snapshot-backed, themed React commit; native activation
waits for that acknowledgment. Until then, the pane keeps a themed loading
surface. Native fallback is shown only if rendering fails.

Native validation of this namespace/startup refinement is pending; the preceding
full validation result above is retained as earlier evidence.
