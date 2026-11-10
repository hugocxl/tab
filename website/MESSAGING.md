# Tab product messaging

## Positioning

**Tab is a fully native terminal multiplexer + agent development environment for
Mac.** Terminal, agent, simulator, and browser panes are first-class citizens.
Its own background server is included.

An ADE is an **agent development environment**: a workspace for coding agents and
the tools used to run, inspect, and test their changes. Explain the acronym on
first use in long-form copy; pair it with the familiar terminal-multiplexer
category in compact headings.

## Reusable descriptions

**Headline**

Your terminal. Your agents. Your whole dev loop.

**Short description / GitHub About**

A fully native terminal multiplexer + agent development environment for Mac.
Terminal, agent, simulator, and browser panes, with its own server included.

**One paragraph**

Tab brings terminal, agent, simulator, and browser panes into one fully native Mac
workspace. Arrange them around your project, work with coding agents beside the
running app, and keep parallel tasks in separate Git worktrees. Written in Swift
and AppKit, Tab includes its own background server to keep terminal sessions alive
when you quit the desktop app.

## Message order

1. **Category and promise:** a terminal multiplexer + ADE, with the whole dev loop
   in view.
2. **The four peers:** terminal, agent, simulator, browser. Give all four the same
   visual weight. Simulators are a core part of the proposition.
3. **Product evidence:** a real screenshot, explicit pane capabilities, projects
   and worktrees, and remote Mac workspaces.
4. **Native craft:** Swift, AppKit, Apple silicon, native controls and shortcuts.
5. **Continuity:** included `tabd` server, reconnecting after app quit, bundled CLI.
6. **Adoption:** macOS requirements, download, installation, provider prerequisites,
   open source, source build.

## Reference analysis

Reviewed November 10, 2026. These are observations about the pages at review time;
competitor positioning can change. We borrow communication principles, not copy,
artwork, layout code, or unverified product claims.

### [Orca](https://www.onorca.dev/)

The category is explicit at the top, then explained through concrete tasks and
workspace surfaces. Product scenes connect abstract agent orchestration to visible
worktrees, diffs, terminals, and browsers. Compatibility details reduce uncertainty
about fitting the tool into an existing workflow.

**Apply:** explain ADE in practical terms, show the product early, name the pane
types and supported native agent integrations. Keep Tab's scope focused enough to
understand quickly. Avoid numerical productivity promises without evidence.

### [Conductor](https://www.conductor.build/)

The opening makes a single outcome easy to remember. Subsequent sections explain
the operating model and account compatibility, supported by product demonstrations
and social proof. The page has a clear hierarchy instead of opening with a feature
inventory.

**Apply:** one memorable headline, then a concrete product definition and a download
action. Explain what the server does through a user benefit. Tab has no supplied
customer evidence, so do not manufacture testimonials, company logos, or usage
numbers. Cloud and multiplayer claims on the reference do not describe Tab.

### [Paradev download](https://paradev.com/download)

The page makes the next action obvious, with a direct download and a visual
installation sequence. It then describes distinct usage surfaces with concrete
examples and platform-specific downloads.

**Apply:** make macOS and Apple silicon requirements visible beside the download,
include the three installation steps, and name what the app bundle contains.
Avoid copying its platform matrix: Tab is for Apple-silicon Macs.

### [Amp](https://ampcode.com/)

Short, outcome-oriented language gives the page energy. A substantial demonstration
of actual work gives the promise substance and shows how the product fits into a
development day.

**Apply:** use short, active headings and show the real app. Ground claims in a
recognizable loop: command, agent, running app, inspection. Do not borrow claims
about continuing work with a closed laptop: Tab's host must remain awake.

### [Bun README](https://github.com/oven-sh/bun)

A small centered mascot, a short name, and compact links establish identity without
a large promotional banner. The body quickly answers what the tool is and how to
start using it.

**Apply:** show Tab's existing mascot alone on transparency at the top, followed by
its name, category, useful links, and a direct explanation.

## Voice and visual direction

Plain, specific, developer-facing. Warm off-white, charcoal, warm ochre-brown
accents, Junicode serif H1/H2 headings, and small monospace labels. Body text and
H3 headings retain the system sans serif. The Junicode Regular Latin font is
self-hosted from [Peek](https://peek.zone/) at the user’s request; its SIL Open Font
License ships alongside the asset. Use the mascot as the brand
anchor and an actual screenshot as evidence. Four equal pane columns reinforce the
product model. Keep the browser-native site lightweight and usable without scripts.

## Claim boundaries

- Native app: Swift and AppKit; the terminal engine is vendored Ghostty.
- Native agent panes: Claude Code and Codex with installed, authenticated CLIs.
  Other CLI agents can run in terminal panes.
- Quit the app: terminal processes remain with `tabd`. Closing their pane ends
  them; sleeping or shutting down the host is not continuous execution.
- Remote: another Mac over SSH, including tunneled browser pages. No claim of
  hosted cloud compute, Linux servers, or browser-based access to Tab itself.
- iOS simulators and Android emulators need their respective installed tooling.
- Tab is MIT licensed. Agent-provider accounts and charges are separate.
