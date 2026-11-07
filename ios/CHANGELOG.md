# Changelog

## 0.8.0 - 2026-11-07

### Changed

- On iPhone, a tab with more than one pane switches between them with a
  segmented control under the navigation bar, each pane named in a word or two.

## 0.7.1 - 2026-11-07

### Fixed

- With more than one Mac, each Mac's heading in the tab list now shows whether
  it's connected instead of staying on "Connecting…".

## 0.7.0 - 2026-11-07

### Changed

- An agent's tool steps read as short sentences, such as "Ran git push" or
  "Edited View.swift +12 −3", and steps in a row share one card.
- Commands leave out the folder change in front of them, and a tapped step
  shows the full command, its output and a failed exit code.

### Fixed

- A running step's spinner no longer covers its text.

## 0.6.0 - 2026-11-07

### Added

- A filter button at the top of the tab list shows only agents, terminals or
  tabs that need attention, and with more than one Mac, one Mac's tabs.

### Changed

- The tab list has a small title instead of a large one, with Settings at the
  top right.

## 0.5.0 - 2026-11-07

### Changed

- On iPhone, the tab list has a search field at the bottom with New Tab
  beside it, as in Notes.

## 0.4.0 - 2026-11-07

### Added

- Attach photos, camera shots and files to a message in an agent pane with the
  + button.

### Changed

- The agent pane's message field has two rows, with Attach, the model and its
  effort, and Send below the text, as in the Claude app.

### Fixed

- Headings, paragraphs, lists and code in an agent's replies have space between
  them.
- Automatically approved and answered permission requests no longer fill the
  transcript.

## 0.3.1 - 2026-11-07

### Fixed

- The app tells your Mac its real version when it connects.

## 0.3.0 - 2026-11-07

### Changed

- The app icon has the desktop's new warm off-white background, with a dark
  variant for the dark Home Screen.

## 0.2.0 - 2026-11-06

### Added

- The desktop's keyboard shortcuts work on an iPad with a keyboard: ⌘T and ⌘⌥A
  for a new terminal or agent, ⌘W and ⌘⇧W to close a pane or tab, ⌘[ and ⌘]
  or ⌘1 to ⌘9 to switch tabs, ⌘⇧[ and ⌘⇧] to move between panes, ⌘B for the
  sidebar, ⌘F to filter and ⌘, for Settings.
- In an agent pane, Return on a hardware keyboard sends the message and
  Shift-Return starts a new line.
- Long press a message, a tool step or a thought in an agent pane to copy it.
- A button jumps back to the newest reply after scrolling up an agent's
  transcript.
- Settings offers Light, Dark or the device's appearance for the whole app.
- An iPad reopens the tab you were in when the app starts.

### Changed

- An agent pane is one kind of pane, with Claude Code or Codex and its model
  chosen from the menu beside the message, as on the Mac. The choice is open
  until the conversation starts, and its card follows it.
- Agent transcripts keep comfortable margins on a phone and a reading-width
  column on a wide iPad pane.
- A failed agent command shows its error above the message field.
- Choosing the tab that is already open keeps it as it is instead of
  reloading it.

## 0.1.0 - 2026-11-06

### Added

- Pair with a Mac running Tab by scanning its pairing code or opening its link.
- See every open tab of your Macs as the desktop sidebar shows them, with what
  each terminal or agent is doing, its branch and its project.
- Type into terminals with a keyboard bar for Escape, Control, Option, Tab,
  arrows and symbols, and scroll back through their history.
- Talk to Claude Code and Codex agents, approve what they ask to run, and stop them.
- Open terminal and agent tabs and panes, which appear on the Mac at once.
- On iPad, see a tab's panes side by side as on the Mac.
