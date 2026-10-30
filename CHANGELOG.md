# Changelog

Every version of Tab, newest first. The app shows this file in Settings →
Changelog.

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

- First release of Tab, the native macOS rewrite of Codesh: projects and
  worktrees in a sidebar, terminal tabs and splits, a command palette, the
  Files and Source Control panels, an editor and diff view, a built-in
  browser, agent sessions, remote servers, mobile access, voice dictation,
  AI commit and pull request drafting, backups and automatic updates.
- The `tab` command line tool and the `tabd` server, which keeps terminal
  sessions running when the app quits.
