# Per-widget examples

This tree holds one directory per Crysterm widget, mirroring the source layout
under `src/widget/`:

```
src/widget/button.cr        ->  tests/widget/button/button.cr
src/widget/graph/bar.cr     ->  tests/widget/graph/bar/bar.cr
src/widget/effect/matrix.cr ->  tests/widget/effect/matrix/matrix.cr
```

Each `<name>/<name>.cr` is a **minimal, self-contained example of a single
widget**. Beside it sit its captures, produced headlessly by `tools/test.cr`:

```
tests/widget/button/button.png      still screenshot
tests/widget/button/button.5s.apng  animation of the script:-driven demo
tests/widget/button/button.dump     text golden (one frame per scripted action)
```

The same machinery covers the **layout engines** under `src/layout/`, mirrored
into `tests/layout/`. A layout isn't a standalone widget — it's installed on a
container (`Box.new ..., layout: Layout::HBox.new`) and arranges the
container's children — so each layout example builds a container and drops
several labeled child boxes into it to show the arrangement.

## Running an example

```sh
crystal run tests/widget/button/button.cr      # interactive — q / Ctrl-Q quits
```

## How the examples are structured

Every example calls the shared harness in [`example.cr`](./example.cr):

```crystal
require "../example"                       # one ../ per directory level deep

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Button" do |window|
  window.stylesheet = "Button { border: solid; }"   # style via CSS (see note)
  Button.new parent: window, top: "center", left: "center",
    width: 22, height: 3, content: "Click me"
end
```

`WidgetExample.run` runs the block in one of several modes:

* **interactive** (default) — a real terminal `Window` + `exec`.
* **screenshot** — when `CRYSTERM_SHOT=<path>` is set, the block is built on a
  *headless* window (all I/O on `IO::Memory`), rendered once, and captured to
  `<path>` via `Window#capture`.
* **animation** / **dump** — `CRYSTERM_ANIM=<path>` records an APNG of the
  `script:`-driven demo; `CRYSTERM_DUMP=<path>` writes one text frame per
  scripted action (the textual golden). See `example.cr`'s header for details.

### Styling note

Set colors and borders through **CSS** (`window.stylesheet = "..."`) so the
whole demo is themed in one place. An inline `style:` constructor argument also
works — like CSS inline style it sits above author rules in the cascade (only
`!important` and state-specific rules outrank it) — and either way it renders
identically whether captured or run live.

## Regenerating the captures

```sh
# Everything under this tree (stale captures only; --force redoes all):
crystal run tools/test.cr -- tests/widget

# Just one or a few examples:
crystal run tools/test.cr -- tests/widget/button tests/widget/calendar
```

One run produces all three outputs (`.png`, `.5s.apng`, `.dump`); `--shot` /
`--anim` / `--dump` scope it to a subset. See `tools/test.cr`'s header for the
full option list, including the `--doc-comments` / `--docs` steps that embed
each widget's capture into its class doc comment and build the API docs.
