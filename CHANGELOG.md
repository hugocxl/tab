# Changelog

Every version of Tab, newest first. The app shows this file in Settings →
Changelog.

## 0.31.1 - 2026-11-02

### Fixed

- Agent messages, changed-file cards and expanded tool results now stay within
  the same maximum message width.

## 0.31.0 - 2026-11-02

### Changed

- Sidebar host headings are smaller and dimmer, and project headings use larger
  icons with compact action buttons that appear on hover.
- Clicking a project heading now expands or collapses its cards.
- Project headings no longer show a globe icon for remote projects.

### Fixed

- Newly added Git projects now show the button for creating a worktree without
  requiring an app restart.

## 0.30.0 - 2026-11-02

### Changed

- Agent conversations and the chat input now use lighter text, and your messages
  have a translucent primary-color background with tighter, consistent line spacing.
- The agent chat input now suggests making changes, mentioning files and running
  commands.

### Fixed

- The answer's copy button now stays hidden while the agent is still working,
  including between tool calls.

## 0.29.0 - 2026-11-02

### Added

- Closing an agent tab now asks for confirmation while the agent is working or
  waiting for input, using the existing running-process confirmation setting.

## 0.28.0 - 2026-11-02

### Changed

- Agent tool calls now show the tool's name and what it ran in a code chip, and an
  opened tool call shows its result in a bordered box.
- A finished agent turn starts with a summary of its tool calls and messages, which
  opens to show the work.
- An agent's answer now shows how long its turn took and when it finished.
- A running agent turn now shows a live timer to a tenth of a second at its bottom,
  instead of a header under your message.
- Agent conversations and the message box are wider, and messages fill at most 80% of
  the width.
- Your messages in an agent chat now have the same rounded corners as sidebar cards.

## 0.27.0 - 2026-11-02

### Changed

- Agent chat suggestions for `/` and `@` are now a compact, translucent list with
  one line per option, centered and tucked behind the message box.
- Agent conversations now run right up to the message box, without a gap.

## 0.26.0 - 2026-11-02

### Changed

- Updates now speak through one floating chip at the bottom right of the window,
  instead of a sheet, alerts and a sidebar card.
- A new version waits for you: Update downloads it in the background with its
  progress, and Restart installs it.
- Restarting for an update that would end running terminals asks first, right in
  the chip.
- Check for Updates shows that it is checking, then whether you're up to date or
  why the check failed, with Try Again.

### Added

- After an update, a chip says which version you're on and opens What's New.
- When this Mac's server still runs an older version, a chip offers to restart it.

## 0.25.1 - 2026-11-01

### Fixed

- Sidebar buttons keep the same gap above and below them as the space between
  panes.

## 0.25.0 - 2026-11-01

### Changed

- The command palette uses the standard font size, smaller icons and slightly
  shorter rows, with bolder row titles.

## 0.24.4 - 2026-11-01

### Changed

- Contributor guidelines no longer ask agents to watch every release build.

## 0.24.3 - 2026-11-01

### Fixed

- A new terminal on a remote server's Home opens under that server in the
  sidebar instead of switching the sidebar to Remote Servers.

## 0.24.2 - 2026-11-01

### Changed

- The readme, license and documentation describe Tab on its own.

## 0.24.1 - 2026-11-01

### Fixed

- Remote servers reconnect when the app starts, so their sidebar cards show
  live agents, branches and activity without being clicked first.

## 0.24.0 - 2026-11-01

### Changed

- Agent conversations draw their controls and tool icons with system symbols,
  matching the rest of the app.

## 0.23.0 - 2026-11-01

### Added

- Sidebar and pane header buttons show a glass tooltip with the action's
  shortcut.
- The sidebar filter opens from its icon into a Filter field, and its menu
  picks All hosts, This Mac or a remote server.
- Typing a host's name in the sidebar filter keeps everything on that host,
  and the matching text is highlighted in the headings.

### Changed

- Sidebar buttons are full circles, and pane header buttons smaller circles;
  the collapsed sidebar toggles match the pane header buttons.
- The + button in the sidebar is a circled plus and its menu also opens a new
  browser, replacing the globe button.
- Add Project moves to a button in the sidebar footer, replacing the row at the
  end of the list.
- Remote server management opens from its own globe button in the sidebar
  footer.
- Buttons side by side in the sidebars keep the same space between their icons.

## 0.22.1 - 2026-11-01

### Changed

- `/clear` in an agent chat starts a new conversation instead of resetting
  Claude's context under the old transcript.
- The `/` menu no longer lists Claude commands that don't work in a chat, or
  skills twice; `/permissions` replaces the duplicate `/access`.

### Fixed

- Messages that start with a file path are sent normally instead of being
  rejected as unknown commands, including follow-ups while the agent works.

## 0.22.0 - 2026-11-01

### Added

- Sidebar cards show how long an agent has been working next to its activity
  indicator.

### Removed

- Sidebar cards no longer show a gray dot when nothing is happening.

## 0.21.2 - 2026-11-01

### Changed

- The bundled third-party notices now credit Ghostty and herdr and list only the
  T3 Code artwork Tab still uses.

## 0.21.1 - 2026-11-01

### Changed

- Release guidelines for contributors now pull the latest changes even with
  uncommitted work in progress.

## 0.21.0 - 2026-11-01

### Changed

- Pane headers show a spinner while an agent works and a dot while it waits
  for you, for agent tabs and agents in a terminal alike.
- Agent tabs show Claude Code's or Codex's logo in their header, as a terminal
  running the same agent does.

### Fixed

- Clicking inside an agent, editor or browser pane makes it the focused pane
  and clears its finished-agent dot.
- Agent tabs take their conversation's title in the tab, window title, sidebar
  filter and Command Palette instead of staying "Agent".

## 0.20.0 - 2026-11-01

### Added

- A Command Palette button next to New Terminal at the top of the sidebar.

## 0.19.1 - 2026-11-01

### Fixed

- A Claude Code follow-up sent while a tool runs no longer leaves the chat
  stuck on working.
- A follow-up sent just as the response finishes starts a new response instead
  of failing.

## 0.19.0 - 2026-11-01

### Changed

- Agent chat composer controls no longer show focus rings.

## 0.18.0 - 2026-11-01

### Added

- Send follow-up messages while an agent works, with active-response steering
  for Codex, queued input for Claude Code, and separate Send and Stop buttons.
- Browse provider-specific chat commands, including Claude session commands
  and personal command files, plus native Codex compaction and code review.

### Changed

- The model picker now groups models into provider submenus.
- Agent chat model, reasoning and access choices persist across restarts and
  become defaults for new conversations.
- Native agent sidebar cards show provider icons, conversation titles and the
  same working, attention and unread completion states as terminal agents.
- The chat input uses a lighter elevated background in light mode.
- Use /new, /skills, /status and /permissions in chat; /clear-draft clears the
  draft without conflicting with provider conversation commands.

## 0.17.0 - 2026-11-01

### Changed

- Agent conversations are now fully native: the bundled web renderer is gone
  and messages, tools, code, tables, images and completed work draw directly
  with AppKit, so the pane opens instantly, uses less memory and no longer runs
  JavaScript.
- The app bundle is about 28 MB smaller without the web renderer's scripts,
  styles and fonts.

### Added

- Math in assistant messages is typeset natively: inline `$…$` and display
  `$$…$$` equations, fractions, roots, sums and integrals, matrices, cases,
  accents and the usual symbol sets, with Copy LaTeX on every equation.
- Mermaid diagrams render natively: flowcharts, state, sequence and class
  diagrams, pie charts, Gantt charts and XY charts, with a Diagram/Source
  toggle, Copy and an Expand view that zooms and pans.
- Code highlighting now covers more than 50 additional languages, including
  Java, Kotlin, C#, PHP, Haskell, Elixir, Terraform, GraphQL, diffs and logs,
  and recognizes the common Markdown fence names for each.
- Find in conversation (Cmd+F) with a match counter, Cmd+G / Shift+Cmd+G
  stepping and highlighted matches in messages, code, tables and plans.
- Select text in an assistant reply to Cite it into the composer, copy it with
  formatting, or copy its original Markdown; following a citation scrolls to
  the quote and highlights it.
- Proposed plans, todo lists, context compactions, errors and notices appear as
  native cards; plans can be copied, downloaded or saved into the workspace.
- Pull-request links show a native card with state, title and author, file
  links show size and modification date on hover, and Codex artifact templates
  offer a Use template button.
- Published HTML and MCP app documents show a native card with an isolated
  preview window, download and copy source.
- Images, videos and audio linked from assistant replies render as native tiles
  and collages with a zoomable gallery, and inline HTML such as `<br>`, `<kbd>`,
  `<sub>`/`<sup>`, anchors and right-to-left spans renders safely.
- Unclosed bold, italic, code and links no longer flash raw markers while a
  reply streams.
- File links offer Open in Editor, Open at Line, Preview, Reveal in Finder and
  Copy Path from their context menu, and @-mentions of other conversations
  render as chips that open that conversation.

## 0.16.0 - 2026-11-01

### Changed

- The selected sidebar card now has a Liquid Glass finish on macOS 26, with
  a frosted look on earlier versions.

## 0.15.0 - 2026-11-01

### Changed

- Working sessions in the sidebar now show an animated six-dot indicator.

## 0.14.1 - 2026-10-31

### Fixed

- Release validation now supports Macs without the optional SF Mono font installed.

## 0.14.0 - 2026-10-31

### Changed

- Agent conversations now render rich Markdown, tool activity, code, tables,
  images, and completed work in a unified conversation view.
- Agent conversations use macOS system fonts and the app's existing themes,
  with the same pane background as terminals.

### Added

- Conversation search, assistant quotations, recorded change previews, and
  richer file and media actions are available directly from agent messages.

### Fixed

- New agent tabs wait for their themed conversation before appearing, avoiding
  a white flash or a brief glimpse of the old empty state.
- Tool attachments remain scoped to their messages, and saving tool images
  no longer blocks other agent conversations.

## 0.13.0 - 2026-10-31

### Changed

- Agent logos in the sidebar are smaller and share the same proportions, so
  no logo looks oversized next to the others.

### Fixed

- Agent logos on dark or white tiles keep a visible edge on dark and light
  themes.
- The Grok logo shows on dark themes instead of a blank white tile.

## 0.12.0 - 2026-10-31

### Added

- The diff viewer colors code with the same syntax highlighting as the editor,
  in both unified and split views.

## 0.11.1 - 2026-10-31

### Fixed

- Host headings in the sidebar sit closer to their icons.

## 0.11.0 - 2026-10-31

### Changed

- When remote servers are configured, the sidebar groups terminals and projects
  under host headings, with extra space between hosts and globe icons for remotes.

## 0.10.0 - 2026-10-31

### Added

- Native Agent Tabs for Claude Code and Codex, with streaming responses,
  tool activity, permission controls, and conversations that resume when reopened.
- Agent composers support @ context, slash actions and skills, and file
  attachments through the picker, paste, or drag-and-drop.
- Model and reasoning choices load from the installed providers, with cached
  catalogs for offline use and a Refresh models action.
- Agent Tabs show provider-reported context usage and offer compact, themed
  model, reasoning, and access controls.

## 0.9.1 - 2026-10-30

### Fixed

- Check for Updates checks for the latest release even when an older update is
  already downloaded, and stale feeds never replace a newer pending update.

## 0.9.0 - 2026-10-30

### Removed

- The project menu no longer has Show Worktrees: a repository's worktrees are
  always listed under it, without the extra gap below them.

## 0.8.0 - 2026-10-30

### Added

- When a new version is downloaded, a card at the bottom of the sidebar offers
  to restart and update, says whether running terminals keep going, and lets
  you wait for them to end or update now.

### Changed

- Updating with an unsaved editor open now tells you to save or close it
  instead of doing nothing.

## 0.7.2 - 2026-10-30

### Fixed

- The window has the standard macOS shadow again instead of a heavy dark one,
  whatever the theme.

## 0.7.1 - 2026-10-30

### Fixed

- Releases no longer fail when a slow build machine makes a terminal speed
  check miss its time limit.

## 0.7.0 - 2026-10-30

### Changed

- Files and Source Control live in a right sidebar: their tabs, the shown
  one highlighted, and its toggle sit above the panel like the left
  sidebar's buttons, and once collapsed the toggle moves into the
  top-right pane and reopens the last tab.
- The Files and Source Control buttons left the left sidebar, and the
  panels no longer have their own close button.

### Fixed

- The Amend checkbox in Source Control no longer squeezes its label onto
  three lines.

## 0.6.0 - 2026-10-30

### Removed

- The Agents panel and the Agent Sessions panel are gone, with their
  shortcuts and menu items; running agents still show on the sidebar cards
  and pane headers.

## 0.5.0 - 2026-10-30

### Changed

- The command palette has a lighter surface, rounder corners, lighter
  section headers and outlined keycaps, and its Return and Actions buttons
  float in a glass capsule over the rows, which fade out beneath it.
- The command palette no longer dims the window behind it; a soft shadow
  lifts it off the window instead.
- The command palette opens lower in the window.

## 0.4.4 - 2026-10-30

### Fixed

- Creating a worktree from the New Worktree dialog no longer fails with
  “Worktree is already registered”.

## 0.4.3 - 2026-10-30

### Fixed

- Clicking a file in the Source Control panel opens its diff again, and
  clicking a group header collapses or expands it.

## 0.4.2 - 2026-10-30

### Fixed

- Releases no longer stop when an earlier version was already published.

## 0.4.1 - 2026-10-30

### Changed

- Every change pushed to Tab is released automatically as its own version,
  with these notes describing it.
- The Settings window has a fixed size and no longer resizes.

### Removed

- The voice settings: dictation always uses the system's language and speech
  model, and inserts what you said without pressing Return.
- The default window size setting: new windows open at 1200×800 points.
- The sidebar width, worktree expansion, unread indicator and worktree
  switcher order settings. Drag the sidebar's edge to resize it; the switcher
  lists the current worktree, then the most recently used.
- The agents panel settings. Show the panel with Command-Option-A or View →
  Toggle Agents Panel; it lists each agent by state.
- Editing settings files by hand: the Edit in… links, the Configuration files
  buttons and the Open Configuration action are gone. Change settings in the
  Settings window.
- AI actions: the AI settings page, Commit with AI, Create Pull Request with AI
  and the Source Control panel's Generate Commit Message button.
- Custom commands, with their Settings page, palette entries and shortcuts.

## 0.4.0 - 2026-10-30

### Added

- Settings has a Changelog page listing what changed in every version, with
  the installed one marked.

## 0.3.0 - 2026-10-30

### Changed

- Settings follows the app's light and dark themes.
- Every change to Tab now ships as a new version.

### Fixed

- Settings opens at the right size, with System Settings spacing.
- The app uses current macOS toolbars and controls instead of the
  compatibility look.
- The main window shows its traffic lights again.

## 0.2.1 - 2026-10-30

### Changed

- Settings is a native window like System Settings: search in the sidebar,
  one page per category, back and forward through visited pages and native
  controls on every page.
- Buttons, switches, pop-up menus, text and search fields across the app are
  native macOS controls that follow the system's appearance and focus.

### Fixed

- Releases no longer fail when a disk image is briefly busy while building.

## 0.2.0 - 2026-10-30

### Added

- First release of Tab, a native macOS terminal workspace: projects and
  worktrees in a sidebar, terminal tabs and splits, a command palette, the
  Files and Source Control panels, an editor and diff view, a built-in
  browser, agent sessions, remote servers, mobile access, voice dictation,
  AI commit and pull request drafting, backups and automatic updates.
- The `tab` command line tool and the `tabd` server, which keeps terminal
  sessions running when the app quits.
