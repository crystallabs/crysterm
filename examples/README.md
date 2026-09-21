This directory contains Crysterm examples, sorted by category.

Examples are functional, reusable programs that you can use or
copy as a base for your projects.

- the "Hello world" from the top-level README lives in `tests/hellos/`
- `template/` — a copy-runnable skeleton for a new application (`shard.yml` +
  `src/main.cr`); start here when copying any example out of this repository
- `claude/` — a Claude-style chat session rendered with rich text (Markdown/GFM)
- `css/` — a whole app styled by one authored CSS stylesheet (no `Style.new`)
- `direct/` — direct (inline) mode: a widget app on the command line, `fzf`-style
- `games/` — commando, minesweeper, pong, wumpus
- `mutt/` — proof-of-concept Mutt-style mail client (mocked content)
- `pine/` — proof-of-concept Pine/Alpine-style mail client (mocked content)
- `screen/` — multiple screens/windows driven by one application
- `terminal/` — `emulator/` (a minimal real terminal emulator) and `tid/` (terminal identification)
- `text/` — a working Unicode text editor built on `TextEdit`

The larger examples are split in two files: `ui.cr` holds the reusable TUI (a
`<Name>UI` class that builds the frame and widgets and offers the chrome
helpers), and the entry file holds the example itself — its data, flows, game
rules and key handling. To build your own app on one of them, copy the
directory, keep `ui.cr` and replace the entry file. The self-driving demos
(`claude`, `direct/completer`, `text/editor`, `screen/multiple`) end in a
section headed "Demo driver" that only exists for the capture; delete it.

Minimal per-widget demos live in `tests/widget/` (see its README).
