# Agent commands — 2026-11-16

Slash commands use a shared parser across the composer and server. Return runs a
selected action or provider command; Tab completes it without executing. Selecting
a skill only inserts its token: the server resolves its instructions on submission.
The initial menu reserves space for every Tab action; `/help` lists the entire
command catalog with available descriptions and argument hints.

## Commands

| Command | Behavior |
| --- | --- |
| `/clear` | Archive the current conversation and reset context in the same pane. Stop active/background work and remove pending queued messages first. |
| `/new` | Open another agent pane. |
| `/resume` | Choose saved provider history. An empty pane takes it over; otherwise it opens beside the current pane. |
| `/fork` | Continue a copy in another pane using the provider's fork support. |
| `/compact` | Compact provider context. Claude accepts optional summarization instructions; Codex rejects arguments. |
| `/review` | Codex: review uncommitted changes. `/review branch <name>` and `/review commit <sha>` select an explicit target. |
| `/skills` | Browse available skills, retaining trailing prompt text. |
| `/skill:<name> <request>` | Resolve the skill on the server, attach local instructions or invoke a provider-owned skill, and execute the request. Menu, paste, direct submission and prompt recall use this same path. |
| `/help` | Search the complete supported command catalog. |
| `/status` | Show provider/model, next-message effort, access, plan mode, activity, queue size and context usage. |
| `/plan [on\|off]` | Toggle or explicitly set plan mode. |
| `/model [model-name\|default]` | Open model selection or set the next-message model. |
| `/effort [level\|auto]` | Open the effort choices or set a supported next-message effort. |
| `/copy` | Copy all retained messages, fetching archived pages first. |
| `/export` | Save the same complete transcript to a Markdown file. |
| `/attach [draft text]` | Open the attachment picker; preserve the remaining draft if cancelled. |
| `/stop` | Stop active work or pause queued work; explain when nothing is running. |
| `/clear-draft` | Remove draft text and attachments. |
| `/outline` | Search loaded prompts, with an explanation when older messages remain unloaded. |
| `/previous-prompt`, `/next-prompt` | Navigate prompts; explain boundaries and load older history when needed. |

Provider-owned prompt commands remain extensible. Terminal-only commands and
configuration commands whose settings Tab does not represent are hidden and
rejected on submission, including argument forms. Unknown commands produce an
explicit error rather than becoming ordinary prompts. Absolute paths containing
slashes and common root-directory prompts remain ordinary text.

## Audit coverage

| Finding | Implementation and regression coverage |
| --- | --- |
| Clear opens a pane | Additive `clear` request; expected-revision guard, archive-before-reset persistence, same session identity, fresh provider context, stale-runtime fencing and reset cache invalidation. Tests cover restart, retries, stale/busy requests and archive-write failure. |
| Arguments bypass routing | Shared `AgentSlashCommand`; local argument validation; native Codex review targets; unsupported compact arguments rejected before a turn or queue entry is created. |
| Typed skills differ from selected skills | No completion-time instruction attachment. Server resolution freezes instructions into the accepted payload; delivery fingerprints exclude generated instructions so a retry after a skill changes or disappears does not replay work. |
| Compaction meter stays stale | Claude post-compaction counts update context usage while retaining capacity. Existing typed compaction cards show before/after counts and completion/failure/interruption. Native Codex lifecycle fixture verifies completion, not just RPC dispatch. |
| Enter behavior differs | Return executes actions and provider commands; Tab only completes. Skills complete a token and await the user's request. |
| Copy omits history | Paginated archive reads for copy/export; attachment names and informational tool rows included. Any history the server did not retain is explicitly identified in the output. |
| Review target misleading | Provider-specific description and explicit uncommitted/branch/commit RPC targets. |
| Hidden commands remain executable | Shared availability rules enforce the same policy at submission, including direct server requests. Unsupported UI settings remain unavailable rather than appearing to change Tab. |
| Metadata lost and actions hidden | Bounded provider discovery returns descriptions/argument hints before the first turn; runtime metadata is retained; core actions reserve menu slots; `/help` is untruncated. |
| Attachments/busy states differ | Per-command attachment rules, working/waiting/queue checks before acceptance, separate draft-free context-chip compaction, and preserved invalid drafts. Commands already accepted by the queue remain deliverable. |
| Skill discovery incomplete | Ancestor roots and configured provider homes, native Codex skill discovery with disabled entries respected, Claude plugin/cloud skill commands and aliases, bounded no-follow reads, dotted names, cached/deduplicated discovery with explicit refresh, and visible omission/unavailability notices. |

## Boundaries

The provider must still be installed, authenticated and support the requested
operation. Discovery has a timeout and falls back to built-in commands/local
skills with an explicit notice. A file-based skill whose instruction resource cannot
be read safely is omitted with a notice; native Claude skills use the provider
command path. Provider/account workflows (publishing,
cloud scheduling, account changes) are not executed merely to test their menu entry.

Clear preserves native provider history and a local archive of Tab's retained
transcript, attachments, outputs and checkpoints. Tab archives follow the existing
closed-conversation retention policy. Clearing does not revert project files.
Older servers that lack the clear request are refused without altering the pane.

Export can recover only history retained by the server. Existing provider fork and
history-import semantics still apply. Automated AppKit and provider-wire fixtures
exercise routing and outcomes; they are separate from a manual acceptance test
against every authenticated provider integration.

## Provider inventory captured during the audit

Claude Code 2.1.311 advertised the following 68 canonical command names. Aliases
use the same availability rules. The live catalog remains provider-owned and is
refreshed by `/skills`, `/help`, and the provider reload commands. The inventory
records routing coverage; state-changing integrations were not executed just to
test their entries. For Tab actions, use the syntax in the first command table.

| Command | Route | Provider argument hint |
| --- | --- | --- |
| `/tab-cli` | Provider skill | — |
| `/deep-research` | Provider command | — |
| `/claude-hud:setup` | Unavailable in pane | — |
| `/claude-hud:configure` | Unavailable in pane | — |
| `/cowork-plugin-management:cowork-plugin-customizer` | Provider skill | — |
| `/cowork-plugin-management:create-cowork-plugin` | Provider skill | — |
| `/design` | Provider command | `consent \| revoke` |
| `/design-sync` | Provider command | `[<project hint, e.g. "Acme DS">]` |
| `/dataviz` | Provider command | — |
| `/update-config` | Unavailable in pane | — |
| `/verify` | Provider command | — |
| `/debug` | Provider command | `[issue description]` |
| `/code-review` | Provider command | `[low\|medium\|high\|xhigh\|max] [--fix] [--comment] [<pr#>\|<branch>\|<path>] [--max-findings <n>\|all]` |
| `/simplify` | Provider command | `[<target>]` |
| `/batch` | Provider command | `<instruction>` |
| `/fewer-permission-prompts` | Unavailable in pane | — |
| `/doctor` | Provider command | `[prompt-audit [<path>]]` |
| `/loop` | Provider command | `[interval] [prompt]` |
| `/schedule` | Provider command | — |
| `/claude-api` | Provider command | — |
| `/workflow-authoring` | Provider command | — |
| `/run` | Provider command | — |
| `/run-skill-generator` | Provider command | — |
| `/plugin-authoring` | Unavailable in pane | — |
| `/advisor` | Provider command | `[fable\|opus\|sonnet\|off]` |
| `/agents` | Unavailable in pane | — |
| `/auto-mode-setup` | Unavailable in pane | `[--request-id <uuid>] (--wizard posture=… scope=… depth=… --propose \| --expect-sha256 <64-hex> --apply-file <path>)` |
| `/autocompact` | Provider command | `[auto\|<tokens>]` |
| `/clear` | Tab action | `[name]` |
| `/color` | Unavailable in pane | `[red\|blue\|green\|yellow\|purple\|orange\|pink\|cyan\|default]` |
| `/compact` | Provider command | `<optional custom summarization instructions>` |
| `/config` | Unavailable in pane | `key=value` |
| `/output-style` | Provider command | `[style]` |
| `/context` | Provider command | — |
| `/effort` | Tab action | `<low\|medium\|high\|xhigh\|max\|auto\|ultracode [on\|off]>` |
| `/fast` | Unavailable in pane | `[on\|off]` |
| `/focus` | Unavailable in pane | `[on\|off]` |
| `/heapdump` | Unavailable in pane | — |
| `/init` | Provider command | — |
| `/mcp` | Provider command | `[reconnect\|enable\|disable [<server>\|all]]` |
| `/import` | Unavailable in pane | — |
| `/model` | Tab action | `<model>` |
| `/__remote-workflow` | Unavailable in pane | — |
| `/workflow-launch-exec` | Unavailable in pane | — |
| `/reload-plugins` | Provider command | `[--force]` |
| `/reload-skills` | Provider command | — |
| `/rename` | Provider command | `[name]` |
| `/security-review` | Provider command | — |
| `/usage-credits` | Provider command | — |
| `/extra-usage` | Unavailable in pane | — |
| `/usage` | Provider command | — |
| `/insights` | Provider command | — |
| `/recap` | Provider command | — |
| `/skill-doctor` | Provider command | — |
| `/goal` | Provider command | — |
| `/design-consent` | Provider command | — |
| `/design-revoke` | Provider command | — |
| `/list-agents` | Provider command | — |
| `/team-onboarding` | Provider command | — |
| `/docs` | Provider skill | — |
| `/docx` | Provider skill | — |
| `/google-workspace` | Provider skill | — |
| `/import-memory` | Provider skill | — |
| `/morning` | Provider skill | — |
| `/pdf` | Provider skill | — |
| `/pptx` | Provider skill | — |
| `/skill-creator` | Provider skill | — |
| `/xlsx` | Provider skill | — |

## Verification

The final warnings-as-errors build, test run, debug bundle, and signature checks
passed with:

```sh
scripts/validate.sh --skip 'TabSimulatorsTests.VideoCodecTests/testFramesEncodeAndDecodeIntoShowableSurfacesAtTheAskedSize'
```

The run executed 2,249 tests, with 33 environment-gated skips and 0 failures.
One additional test, the simulator hardware-video encode/decode test named above,
was excluded after two unfiltered runs stalled inside macOS VideoToolbox's
`VTPixelTransferSessionTransferImage` / `IOSurfaceAcceleratorTransformSurface`.
The bitrate test and all remaining simulator tests ran. Unfiltered validation
therefore remains blocked by that host issue; the simulator implementation and its
tests were not changed.
