# Per-widget (and per-layout) examples

This tree holds one directory per Crysterm widget, mirroring the source layout
under `src/widget/`:

```
src/widget/button.cr        ->  examples/widget/button/button.cr        (+ button-capture.png)
src/widget/graph/bar.cr     ->  examples/widget/graph/bar/bar.cr        (+ bar-capture.png)
src/widget/effect/matrix.cr ->  examples/widget/effect/matrix/matrix.cr (+ matrix-capture.png)
```

The same machinery also covers the **layout engines** under `src/layout/`, mirrored
into `examples/layout/`. A layout isn't a standalone widget — it's installed on a
container (`Box.new ..., layout: Layout::HBox.new`) and arranges the container's
children — so each layout example builds a container and drops several labeled
child boxes into it to show the arrangement:

```
src/layout/hbox.cr   ->  examples/layout/hbox/hbox.cr   (+ hbox-capture.png)
src/layout/grid.cr   ->  examples/layout/grid/grid.cr   (+ grid-capture.png)
```

Each `*.cr` is a **minimal, self-contained example of a single widget**. A widget
that genuinely needs alternative examples gets `name.cr`, `name2.cr`, `name3.cr`.
Beside each example is its screenshot, named `<widget>-capture.png` for the first
program, `<widget>-capture2.png`, `<widget>-capture3.png`, ... for any further ones.

Everything here is generated and maintained by
[`tools/widget-examples.cr`](../../tools/widget-examples.cr) — see its header for
options. It never overwrites an existing example unless you pass `--force`, so
hand-tuned examples are safe.

## Running an example

```sh
crystal run examples/widget/button/button.cr      # interactive — q / Ctrl-Q quits
```

## How the examples are structured

Every example calls the shared harness in [`example.cr`](./example.cr):

```crystal
require "../example"                       # one ../ per directory level deep

Crysterm::WidgetExample.run "Button" do |screen|
  screen.stylesheet = "Button { border: solid; }"   # style via CSS (see note)
  Crysterm::Widget::Button.new parent: screen, top: "center", left: "center",
    width: 22, height: 3, content: "Click me"
end
```

`WidgetExample.run` runs the block in one of two modes:

* **interactive** (default) — a real terminal `Screen` + `exec`.
* **screenshot** — when `CRYSTERM_SHOT=<path>` is set, the block is built on a
  *headless* screen (all I/O on `IO::Memory`), rendered once, and captured to
  `<path>` via `Screen#capture`. This is how the tool snapshots every widget
  with no real terminal involved.

### Styling note

Set colors and borders through **CSS** (`screen.stylesheet = "..."`), not the
legacy `style:` constructor argument. The CSS cascade computes each widget's
style every frame and discards inline `style:` values it doesn't also see as
CSS, so only CSS-applied styling actually renders — and it renders identically
whether captured or run live.

## Regenerating / screenshotting

```sh
# Fill in everything still missing, and screenshot it:
crystal run tools/widget-examples.cr --

# Just one or a few widgets:
crystal run tools/widget-examples.cr -- button calendar

# Rebuild a widget's example from its recipe:
crystal run tools/widget-examples.cr -- --force calendar

# See the plan without writing anything:
crystal run tools/widget-examples.cr -- --list
```

Widgets without a tailored recipe fall back to a generic template (a plain box
showing the widget's name). The tool reports those at the end so they can be
groomed into real examples over time by adding a recipe to its `RECIPES` table.

## Showing the captures in `crystal docs`

Each widget's API documentation embeds its capture. The tool keeps a small
managed block inside the widget's **class doc comment** (in `src/widget/*.cr`),
fenced by HTML comments so it can be refreshed or migrated without touching
hand-written prose. It prefers the **animation** (`<prog>-capture<secs>s.apng`,
which browsers play inline) and falls back to the still (`<prog>-capture.png`)
when there is no APNG:

```crystal
    # <!-- widget-examples:capture v1 -->
    # ![List screenshot](../../examples/widget/list/list-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class List < Widget
```

`crystal docs` emits that `<img src>` verbatim, resolved relative to the class's
generated page (`docs/Crysterm/Widget/List.html`); the `../` prefix (one per
namespace level) walks back to the docs root. So the doc steps are:

```sh
# 1. Record the animations (and stills) you want shown.
crystal run tools/manage-examples.cr -- --anim          # APNGs for all examples
# 2. Insert/refresh the capture block in every source doc comment (idempotent;
#    migrates an older block; now points at the APNG where one exists).
crystal run tools/manage-examples.cr -- --doc-comments
# 3. Build the API docs and copy examples/ into the docs tree so the references
#    resolve (runs `crystal docs`, then copies to docs/examples/).
crystal run tools/manage-examples.cr -- --docs
```

Step 1 edits source files (commit those); step 2 only produces `docs/` (which is
git-ignored). The set of trees copied into `docs/` is the `DOCS_ASSETS` constant
in the tool.
