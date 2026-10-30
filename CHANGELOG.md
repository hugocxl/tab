# Changelog

Every version of Tab, newest first. The app shows this file in Settings →
Changelog.

## 0.4.1 - 2026-10-30

### Changed

- Every change pushed to Tab is released automatically as its own version,
  with these notes describing it.

## 0.4.0 - 2026-10-30

### Added

- Settings has a Changelog page listing what changed in every version, with
  the installed one marked.

### Changed

- The Settings window has a fixed size and no longer resizes.
- Contributor instructions require pulling `main` before every commit, so
  versions in the changelog don't collide.

### Removed

- The voice settings: dictation always uses the system's language and speech
  model, and inserts what you said without pressing Return.
- The default window size setting: new windows open at 1200×800 points.
- The sidebar width, worktree expansion, unread indicator and worktree
  switcher order settings. Drag the sidebar's edge to resize it; the switcher
  lists the current worktree, then the most recently used.
- AI actions: the AI settings page, Commit with AI, Create Pull Request with AI
  and the Source Control panel's Generate Commit Message button.
- Custom commands, with their Settings page, palette entries and shortcuts.
- Editing settings files by hand: the Edit in… links, the Configuration files
  buttons and the Open Configuration action are gone. Change settings in the
  Settings window.
- The agents panel settings. Show the panel with Command-Option-A or View →
  Toggle Agents Panel; it lists each agent by state.

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
