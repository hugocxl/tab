# Changelog

Every version of Tab, newest first. The app shows this file in Settings →
Changelog.

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
