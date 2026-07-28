# Crysterm features

Crysterm is a feature-complete toolkit for terminal (TUI) applications in
[Crystal](https://crystal-lang.org), inspired by Qt and Blessed. This page
tours the main features; every animation links the program that produced it,
so each one is also a working, copyable example. All captures are made by the
toolkit itself (see [Screen capture](#screen-capture)) at the standard 80×24
screen size.

## Qt-like widget set — 90+ widgets

More than 90 concrete widgets with Qt-modeled APIs and behavior:
`MainWindow` (menu bar / tool bars / status bar / dock widgets), `Menu` and
`MenuBar` with nested submenus, `TabWidget`, `Splitter`, `Tree`, `Table`,
`List`, text widgets (`LineEdit`, `PlainTextEdit`, `TextEdit`,
`TextBrowser`), value widgets (`Slider`, `SpinBox`, `DoubleSpinBox`, `Dial`,
`LCDNumber`, `ProgressBar`), date/time widgets (`Calendar`, `DateEdit`,
`TimeEdit`, `DateTimeEdit`), a full `ColorDialog` palette picker (HSV field,
RGB/HSV/HSL entry, custom colors — even an eyedropper that samples the
screen), `SplashScreen`, `SizeGrip`, `ToolTip`s, `Completer`, dialogs and
button boxes, plus terminal-native extras: charts and gauges
(`Graph::LineChart`, `Bar`, `PieChart`, donuts), `BigText`, media widgets,
effects, and a complete in-process terminal emulator (`Widget::Terminal`).

![](tests/misc/qt_widgets.5s.apng)

*Source: [tests/misc/qt_widgets.cr](tests/misc/qt_widgets.cr) — see also
[tests/misc/widgets.cr](tests/misc/widgets.cr) and per-widget demos under
[tests/widget/](tests/widget/).*

## Layouts

As in Qt, widgets are best positioned by layout engines rather than by
absolute coordinates — set `widget.layout =` and add children, with per-child
`layout_hint:` tuning. Eleven engines ship: `HBox` / `VBox` (over a
flexbox-style `Box` engine — `spacing`, `stretch`, `justify`, `align`),
`Grid` (spans, auto-flow), `Form` (label/field rows), `Border` (five-region
dock), `Stack` (cards), `Wrap`, `UniformGrid`, `Masonry` and `Manual`. The
same five widgets arranged by six engines:

![](tests/misc/layouts.png)

*Source: [tests/misc/layouts.cr](tests/misc/layouts.cr) — one demo per engine
under [tests/layout/](tests/layout/).*

## CSS and QSS styling

A complete CSS engine styles widgets by selector: paddings, margins, borders
(including per-side and radius), colors, shadows, opacity, transitions, and
pixel measures translated to cells via the terminal's real cell geometry.
It also reads Qt's QSS dialect directly — unmodified desktop Qt themes style
terminal apps. Six independent windows below run the same scene, each loaded
with a different theme from [data/css/](data/css/)
(`--colors-stylesheet data/css/<name>.qss` on any Crysterm program, or
`window.load_stylesheet`), while one script drives them all — opening the
File menu, then filtering and committing a completion:

![](tests/misc/themes.5s.apng)

*Source: [tests/misc/themes.cr](tests/misc/themes.cr)*

![](tests/misc/styling.5s.apng)

*Source: [tests/misc/styling.cr](tests/misc/styling.cr)*

## Rich text — Markdown with GFM

`TextDocument` (a QTextDocument work-alike) imports and exports **Markdown
(CommonMark + GFM)**, **HTML** and Crysterm's native tags, and
`TextEdit`/`TextBrowser` render it: headings, bold/italic/strikethrough,
inline code and links, fenced code blocks, blockquotes, GFM tables laid out
as real box-drawing tables, GFM task lists, and GFM alert admonitions —
themable via `TextTheme`, editable with full undo, navigable links. Below, a
Claude-style session streams a reply in as Markdown:

![](examples/claude/claude.5s.apng)

*Source: [examples/claude/claude.cr](examples/claude/claude.cr)*

## Syntax highlighting

`SyntaxHighlighter` mirrors Qt's `QSyntaxHighlighter`: subclass it, implement
`highlight_block`, and attach it to any `TextDocument` — formats overlay the
text without touching content, undo or export; multi-line constructs carry
state between blocks, and multiple highlighters can stack on one document.

![](tests/misc/syntax.png)

*Source: [tests/misc/syntax.cr](tests/misc/syntax.cr)*

## Full Unicode

Unicode-native end to end: grapheme clusters (ZWJ emoji, combining marks),
wide CJK cells, ambiguous-width resolution probed from the live terminal,
East Asian width, and glyph chrome that auto-upgrades on modern-font
terminals. The working editor below — menu bar, tool bar with Unicode icon
buttons, status bar with live Ln/Col — types and edits multilingual text:

![](examples/text/editor/editor.5s.apng)

*Source: [examples/text/editor/editor.cr](examples/text/editor/editor.cr)*

## Native TrueColor

Colors are stored as full 24-bit RGB and reduced to the terminal's real
capability only at output time (16.7M → 256 → 16 → 8 colors, automatically).
Alpha compositing blends colors per channel in RGB space — translucent
widgets, soft shadows, smooth gradients:

![](tests/misc/truecolor.5s.apng)

*Source: [tests/misc/truecolor.cr](tests/misc/truecolor.cr)*

## Hardware and artificial cursors

Cursor shape (`block` / `underline` / `bar`), blink and color are settable
per window *and* per widget — each focused widget can present its own cursor.
When the terminal can't style its hardware cursor (or a custom glyph/style is
requested), Crysterm transparently composites an *artificial* cursor into the
cell buffer instead, re-deciding hardware-vs-artificial every frame:

![](tests/misc/cursors.5s.apng)

*Source: [tests/misc/cursors.cr](tests/misc/cursors.cr)*

## Border docking with color blending

Adjacent and overlapping borders dock into shared junction glyphs
(`├ ┬ ┼ …`) — enable with `window.dock_borders = true`. When the touching
borders differ in color, `dock_contrast` chooses: `Ignore` (join anyway),
`Skip` (keep both), or `Blend` (mix the colors for the smoothest seam):

![](tests/misc/docking.5s.apng)

*Source: [tests/misc/docking.cr](tests/misc/docking.cr)*

## `{}` tags in strings

Any widget content can carry inline tags (`parse_tags: true`): named and hex
colors (`{red-fg}`, `{#57c7ff-bg}`), attributes (`{bold}`, `{underline}`,
`{inverse}`, `{blink}`), proper nesting with state restore, alignment
(`{center}`, `{right}`, and `{|}` for left/right split), `{open}`/`{close}`
literals and `{escape}…{/escape}` for untrusted text:

![](tests/misc/tags.5s.apng)

*Source: [tests/misc/tags.cr](tests/misc/tags.cr)*

## Loadable fonts

`BitmapFont` loads GNU Unifont `.hex` and ttystudio `.json` fonts —
`BigText` renders text with them in the terminal, and the capture pipeline
rasterizes screenshots through them. Terminus and Unifont faces ship in
[data/font/](data/font/).

![](tests/misc/fonts.png)

*Source: [tests/misc/fonts.cr](tests/misc/fonts.cr)*

## Rich media — images and video

One `Media` widget, twenty-one backends, selected automatically per terminal
and per content (`--media-backend=auto`) or forced by config/CLI/env/code:

* **In-band pixels** — Kitty graphics, iTerm2 inline images, Sixel, ReGIS
* **Sub-cell glyphs** — octant (2×4), braille (2×4), sextant (2×3),
  quadrant (2×2), half (1×2), block, ASCII
* **ANSI cells** — TrueColor, 256, 16, 8 colors
* **External** — w3m overlay, überzug, Tektronix 4014

Formats: PNG, APNG, GIF (stills *and* animations), JPEG (iTerm pass-through),
ANSI/BBS art (`.ans`, `.nfo`, …), and `http(s)://` sources. Fit modes:
`stretch`, `contain` (aspect-preserving), `cover`, `none`. Four backends per
window, same image, aspect ratio preserved:

![](tests/misc/media_graphics.png)

![](tests/misc/media_glyph.png)

![](tests/misc/media_ansi.png)

*Sources: [tests/misc/media_graphics.cr](tests/misc/media_graphics.cr),
[tests/misc/media_glyph.cr](tests/misc/media_glyph.cr),
[tests/misc/media_ansi.cr](tests/misc/media_ansi.cr)*

**Video** plays through the same widget via ffmpeg (`Widget::Video`): mp4,
mkv, webm, mov, avi, mpeg, ts, 3gp and more, with eager or constant-memory
streaming decode (`media.video_decode=auto|eager|stream`):

![](tests/misc/video.5s.apng)

*Source: [tests/misc/video.cr](tests/misc/video.cr)*

## Animated images

APNG and GIF animations play in every backend, with per-frame delays honored
and multiple widgets optionally driven in lockstep from one shared timer —
here the same GIF in four backends at once:

![](tests/misc/animated.5s.apng)

*Source: [tests/misc/animated.cr](tests/misc/animated.cr) — see also
[tests/misc/netscape.cr](tests/misc/netscape.cr)*

## Terminal feature auto-detection

At startup Crysterm probes the live terminal — truecolor (DECRQSS),
graphics protocols (Kitty/iTerm/Sixel), Unicode and ambiguous width,
palette and default colors, cursor styling, kitty keyboard protocol,
in-band resize, pixel mouse, cell pixel geometry — and picks the best
supported settings; every probed fact records its provenance. The same
gauges render as braille sub-cells on a plain terminal and as real pixels
on a Kitty-graphics terminal, untouched:

![](tests/misc/detect.png)

*Source: [tests/misc/detect.cr](tests/misc/detect.cr) — probe internals:
`Tput#probe!`, `Tput::Features`, `Tput::Emulator`.*

## Everything tunable — 69 settings

Every hardcoded value is an option in one registry (built on `superconf`),
each settable four synchronized ways — config file
(`~/.config/crysterm/config.yml`), env (`CRYSTERM_*`), CLI flag, or code —
69 settings and counting, available in any Crysterm program with zero setup:

```sh
crystal run app.cr -- --dump-config=pretty   # list every option + provenance
crystal run app.cr -- --media-backend=sixel  # force a graphics backend
CRYSTERM_MEDIA_BACKEND=kitty crystal run app.cr
```

## Direct (inline) mode

Apps can run on the command line without taking over the screen. Two
flavors: `Crysterm::Direct` for styled printing into the normal scrollback
(no widgets, no loop — see [tests/misc/direct.cr](tests/misc/direct.cr)),
and **inline windows** (`Window.new inline: true`, optionally
`auto_grow: true, max_height:`) — the *complete* widget stack, popups and
all, anchored at the shell cursor like `fzf`. A completer on a command line:

![](examples/direct/completer/completer.5s.apng)

*Source:
[examples/direct/completer/completer.cr](examples/direct/completer/completer.cr)*

## Multiple screens

One process can drive several terminal windows: `Application.open` spawns a
real emulator window and returns a `Window` for it, `Application.run
(window_count: N)` opens N, `Application.exec_all` runs any set under one
shared loop, and windows migrate between devices with `connect`/`disconnect`.
Below, a value assigned on the left screen updates the right one through a
shared reactive signal (run with `--spawn` for two real windows):

![](examples/screen/multiple/multiple.5s.apng)

*Source:
[examples/screen/multiple/multiple.cr](examples/screen/multiple/multiple.cr)*

## Full mouse support

All the protocols — X10, SGR (1006), URxvt (1015), **SGR-Pixels** (1016,
sub-cell pixel coordinates), and GPM on the Linux console — with hover,
enter/leave, capture, double/triple-click counting, wheel scrolling, focus
reporting (1004), and a GUI pointer shape over hovered widgets (OSC 22).
Real **drag & drop** with MIME-typed payloads (`text/uri-list`, …),
Move/Copy/Link actions negotiated by modifiers, and the same sessions driven
by keyboard. The editor demo above opens its menu and scrolls by mouse.

## Paste buffer, kill-ring, undo/redo

Text widgets share a process-wide Emacs **kill-ring** (`C-k`/`C-u`/`C-w`
kill, `C-y` yank, consecutive kills merge — kill in one field, yank in
another), a full **undo/redo stack** on the document model (`C-z`/`M-z`,
grouped edit blocks, format-preserving), GUI clipboard keys (`C-c`/`C-x`/
`C-v`), **bracketed paste** (DEC 2004), and the **system clipboard** over
OSC 52 — copy/paste that works through SSH and tmux.

## Reactive programming

A fine-grained signals system (SolidJS-style): `Reactive::Signal`,
`Reactive.computed`, effects with automatic dependency tracking,
widget-lifetime `Reactive.bind`, `ObservableList` for collection views,
batching, and a `reactive_property` macro for widget classes. Assign
`signal.value = x` — every bound widget repaints itself:

![](tests/misc/reactive.5s.apng)

*Source: [tests/misc/reactive.cr](tests/misc/reactive.cr) — full tour:
[tests/reactive/reactive.cr](tests/reactive/reactive.cr)*

## High-performance rendering

The renderer combines **compositing** with **damage tracking** — and
measures itself: it times the selective path against the full path (moving
averages, periodic re-probe) and automatically uses whichever is faster for
the workload. Output is a minimal cell-level **diff** against what the
terminal already shows, with CSR/BCE scroll optimizations and optional DEC
2026 synchronized output. The `Fps` widget reports render/draw/flush times
and terminal bandwidth live:

![](tests/misc/quicktro.5s.apng)

*Source: [tests/misc/quicktro.cr](tests/misc/quicktro.cr) — see also
[tests/misc/concurrent_rendering.cr](tests/misc/concurrent_rendering.cr)*

## Screen capture

Any window or single widget captures itself — in-process PNG encoding, plus
APNG/GIF/MP4/WebM/JPEG via ffmpeg, and a textual `.dump` golden format —
including live recording of a running UI at a chosen fps, and compositing of
in-band graphics (sixel/kitty/iterm) into the capture. Setting
`CRYSTERM_SHOT` / `CRYSTERM_ANIM` / `CRYSTERM_DUMP` makes *any* Crysterm
program capture itself headlessly — every image on this page was produced
that way:

![](examples/games/minesweeper/minesweeper.5s.apng)

*Source:
[examples/games/minesweeper/minesweeper.cr](examples/games/minesweeper/minesweeper.cr)*

## Scripting and automation

Synthetic input goes through the exact code paths real input uses:
`window.emit Event::KeyPress, ...` and `window.dispatch_mouse ...`. The
bundled harness ([tests/widget/example.cr](tests/widget/example.cr)) builds
on that with a scripting driver — `d.key`, `d.type`, `d.click`, `d.act`,
dwell timing — used by ~200 widget demos to film themselves, and equally
usable for in-app automation and testing.

## Remote control

Built with `-Dremote`, an app exposes its **widget tree as a DOM** over
HTTP: JSON-RPC commands (`setContent`, `addClass`, `focus`, `append`,
`query`, `snapshot`, …) addressed by full CSS selectors, and UI events
streamed out over Server-Sent Events — so app behavior can live in another
process, written in any language. The layout side works without the network,
too: `Window#load_layout` builds the UI from HTML + CSS, queryable and
updatable in-process:

![](tests/misc/dom.5s.apng)

*Source: [tests/misc/dom.cr](tests/misc/dom.cr) — the bundled `crysterm run
app.html --handler "python3 app.py"` CLI is in `src/remote/bin/`.*

## Ready-to-use example apps

Programs under [examples/](examples/) are complete, usable applications,
meant as templates for your own: a [Pine-style mail client](examples/pine/),
a [Mutt-style mail client](examples/mutt/), the
[Claude-style session](examples/claude/) above, a working
[terminal emulator](examples/terminal/emulator/) and
[multiplexer](examples/terminal/tid/), the
[Unicode text editor](examples/text/editor/), and
[games](examples/games/) (Minesweeper, Pong, Commando, Wumpus).

## And more

* **Terminal widget** — a real VT-emulating terminal inside your UI (ptys,
  colors, mouse), enabling multiplexers and embedded shells.
* **Charts** — line/bar/pie/donut/sparkline graph widgets on a
  backend-agnostic canvas that upgrades from braille to real pixels.
* **Effects** — animated widget effects (e.g. Matrix rain), marquees,
  gradients, shadows with true alpha.
* **Hyperlinks** — OSC 8 clickable links tracked per cell.
* **Keyboard** — kitty keyboard protocol and modifyOtherKeys, probed and
  enabled automatically.
* **GPM** — mouse on the bare Linux console.
* **ANSI art** — CP437 `.ans`/`.nfo` art decoded and rendered with sub-cell
  detail.
* **Docs with pictures** — `crystal docs` embeds each widget's capture into
  its API documentation automatically.

The in-depth introduction is in [USAGE.md](USAGE.md).
