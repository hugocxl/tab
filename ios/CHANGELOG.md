# Changelog

## 0.27.0 - 2026-11-14

### Added

- A turn that changed files ends with them; tap to read each file's recorded
  diff, comment on its lines, and add the comments to your message.
- Agents running in the background show above the message box with their
  progress, and tapping one shows the step that started it.
- The current task list's progress shows above the message box, and tapping it
  shows the list.
- The pane menu lists the conversation's prompts to search and jump to, and
  moves to the previous or next prompt.
- Continue a conversation Claude Code or Codex saved for the folder, from the
  pane menu, here when nothing has been said yet or in a new pane beside it.

### Changed

- Stop stays beside Send while you type a follow-up as the agent works.
- Queued prompts are edited in a sheet with room for several lines, and keep
  their place and menus as the agent works.
- The cards above the message box scroll together when the pane is short.
- Submitting a question with a required answer missing shows that question.

### Fixed

- The working timer pauses while the agent waits for your answer, and finished
  turns leave that wait out of their time.
- Closing a pane or tab whose agent is working, or runs agents in the
  background, asks before stopping them.

## 0.26.0 - 2026-11-12

### Added

- Tap a project's header in the tab list grouped by project to hide or show its
  tabs, as in the Mac's sidebar; hidden projects stay hidden next time and say
  how many tabs they hold.
- A project's header has a menu to add a terminal or agent pane to the project,
  start a new worktree of a Git project, or copy its path.

## 0.25.0 - 2026-11-12

### Changed

- Terminals use the Mac's new warm light and dark Tab themes, with clearer text
  and ochre accents.

## 0.24.1 - 2026-11-11

### Fixed

- Swiping in a terminal now scrolls programs that use the mouse, such as Claude
  Code, instead of doing nothing.

## 0.24.0 - 2026-11-10

### Changed

- Tab icons now use the same IconsCXL library as the Mac app.

## 0.23.0 - 2026-11-10

### Added

- Group the tab list by project from the filter menu or Settings, as the Mac's
  sidebar does in its Projects layout.

## 0.22.0 - 2026-11-10

### Added

- Answer an agent's questions in a form above the message box, with its
  choices, your own answer and private answers that are never saved.
- Prompts waiting for the agent show above the message box, where you can edit,
  move, send now or remove them, and resume them after the Mac pauses them.
- Turn plan mode on from the model menu or with Shift-Tab on an iPad keyboard,
  and off with its chip in the message box.
- Dictate a message with the button in the message box; the words are
  recognized on your iPhone or iPad.
- Images sent with a message show in the conversation, several of them in a
  compact grid.
- Place a pane at the left, right, top or bottom of its tab in thirds, halves or
  two thirds from the pane menu, keeping the other panes together.

### Changed

- An agent pane keeps its unsent message, files and answers when you leave it or
  quit the app, and a message sent again after a lost connection isn't taken
  twice.
- The message box has a larger attach button, one picker for the model and its
  reasoning effort, and one button that sends, stops or dictates.
- The conversation scrolls behind the message box and the cards above it.
- A question shows only in its form, not also in the conversation.
- New agent panes no longer offer an access setting; they use the Mac's default.
- Tabs from a Mac that isn't connected show dimmed in the list until it
  connects.
- Project icons and Git branches on cards appear as soon as the app opens, from
  what it showed last time, and update once the Mac answers.
- The selected card in the iPad sidebar sits on translucent glass.
- Closing the last tab or pane of a worktree asks whether to remove the worktree
  and its files, says what would be lost, and keeps everything open when you
  cancel.

### Fixed

- An agent pane opens at its newest message, and stays there as images and long
  replies load.
- The pane switcher no longer stays on screen after its tab closes.

## 0.21.0 - 2026-11-10

### Changed

- An agent's message box sits just above the bottom edge of the screen, with no
  extra space beneath it.

## 0.20.0 - 2026-11-09

### Changed

- Tab cards and agent panes draw their icons from Tab's own two-tone icon set,
  with agent, file and tool marks in their own colors, as on the Mac.
- A terminal's row shows an icon for the command running in it, such as node,
  npm, pnpm or python.
- Browser and simulator panes have colored marks that match terminal and agent
  panes.
- A card's Git line shows a plain branch icon.

## 0.19.1 - 2026-11-09

### Fixed

- A tab card's Git branch line no longer collapses under its title's icon when
  the branch arrives after the list appears.

## 0.19.0 - 2026-11-09

### Changed

- Long pressing a message's text in an agent pane selects it, so you can copy
  part of the message; tool output and thoughts still copy whole.

## 0.18.0 - 2026-11-09

### Changed

- Pane rows on a tab card show each pane's icon while it is idle and its status
  while it works, in place of an empty circle.
- A card's title shows its pane's icon, or an empty circle while several panes
  are idle, and the most pressing status among its panes.
- A shell's full folder follows its name in a card's title and pane rows, and
  Home cards no longer add a folder line.

## 0.17.0 - 2026-11-08

### Changed

- Tab cards follow the redesigned desktop sidebar: a title that says what the
  tab is about, every pane with what it is doing, then the folder or Git branch
  and the project below them.
- Pane statuses use system symbols, with a spinner while an agent works, and
  terminals, folders and Git use Pierre's colored icons.
- On iPhone, the tab list is a plain list again, with cards flush and hairlines
  between them, and a project's own checkout is marked primary as on the Mac.

## 0.16.0 - 2026-11-08

### Changed

- On iPhone, the tab list is an inset grouped list, with the tabs in one rounded
  card.

## 0.15.0 - 2026-11-08

### Changed

- The Tab and Tab Light themes and the app's accent pair Cursor's quiet neutral
  grays with Claude's warm terracotta and softer colors.

## 0.14.1 - 2026-11-08

### Changed

- Lists and transcripts fade softly under the top bar as they scroll, with no
  border line.

## 0.14.0 - 2026-11-08

### Changed

- Filter and Settings sit together at the top right of the tab list, and New Tab
  is a compose button.

## 0.13.0 - 2026-11-08

### Changed

- New panes opened from the phone go below the current pane, stacked
  vertically on the Mac, instead of beside it.

## 0.12.2 - 2026-11-08

### Changed

- Sending a message to an agent closes the keyboard, so you can read the
  reply.

## 0.12.1 - 2026-11-08

### Changed

- Groups of tool calls in an agent's transcript have more space around them,
  so the conversation is easier to read.

## 0.12.0 - 2026-11-07

### Added

- A full set of terminal keys above the keyboard: symbols, arrows, Shift,
  Control and Option on one page, and F1 to F12, Home, End, Page Up, Page Down,
  Delete and Paste on a second.
- Settings → Terminal → Keys chooses between the full keys and the compact
  single row; iPhone starts with the full keys and iPad with the compact row.

### Changed

- Tapping Shift, Control or Option twice quickly locks it until you tap it
  again.

## 0.11.0 - 2026-11-07

### Added

- New Tab opens a sheet to choose a terminal, agent or simulator, the Mac, and
  any project or worktree to open it in, searchable like the desktop's command
  palette.
- In a Git project, New Tab can open the tab in a new worktree: name its branch
  or type a pull request number like #123, choose the branch it starts from,
  and fetch that branch from its remote first.
- On iPad, Command-Shift-N and Command-Shift-O open New Tab for a terminal or an
  agent, as on the Mac.

### Changed

- New Tab remembers the kind, agent and checkout you chose last.

### Removed

- The Open Project list in the New Tab menu, now that New Tab opens in any
  project.

## 0.10.1 - 2026-11-07

### Changed

- Tab declares its privacy details and encryption use for the App Store, ready
  for TestFlight.

## 0.10.0 - 2026-11-07

### Changed

- On iPhone, the pane switcher spans the full width of the screen, with each
  pane given an equal share.

## 0.9.0 - 2026-11-07

### Added

- Simulator tabs and panes show an iOS simulator or Android emulator running
  on the Mac, live, to tap, swipe and type into with the phone's keyboard or a
  hardware keyboard.
- A simulator pane lists the Mac's simulators to choose from, starts one that
  is shut down, and offers Home, Back, rotation, dark appearance, pasting text
  and a screenshot to share.
- Simulator panes opened on the Mac now show here instead of a placeholder.

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
