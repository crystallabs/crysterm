# Crysterm

This is a more in-depth developer guide. It is organized as follows:

1. [Introduction](#1-introduction)
2. [Getting started](#2-getting-started)
3. [Architecture](#3-architecture)
4. [Positioning and sizing](#4-positioning-and-sizing)
5. [Decorations](#5-decorations)
6. [Styling](#6-styling)
7. [Text, attributes, and colors](#7-text-attributes-and-colors)
8. [Rendering and drawing](#8-rendering-and-drawing)
9. [The cursor](#9-the-cursor)
10. [Performance and FPS](#10-performance-and-fps)
11. [Differences from Blessed](#11-differences-from-blessed)

---

## 1. Introduction

A Crysterm program is built from a small number of key pieces; 
one or more `Screen`s, hierarchical tree of `Widget`s placed on them,
and `Style` objects for visual look.

Widgets are placed in various types of auto-arranging layouts or positioned
with a flexible scheme (absolute integers, percentages,
or keywords such as `"center"`), decorated with borders/padding/shadow/frame, and
filled with content that may contain inline markup ("tags") for colors and
attributes. The screen renders the whole tree into an off-screen cell buffer
and then emits only the minimal set of terminal escape sequences needed to make
the changes, using the differential ("damage") renderer.

It is supported by shards implementing the event model in 
[event_handler](https://github.com/crystallabs/event_handler), color routines in
[term_colors](https://github.com/crystallabs/term_colors), terminal handling in
[tput.cr](https://github.com/crystallabs/tput.cr), GPM mouse in
[gpm.cr](https://github.com/crystallabs/gpm.cr), a terminfo library in
[unibilium.cr](https://github.com/crystallabs/unibilium.cr), and an animated PNG/GIF parser
in [pnggif](https://github.com/crystallabs/pnggif).

[tput.cr](https://github.com/crystallabs/tput.cr) implements all the terminal routines, and
does not use ncurses. For terminfo bindings it uses [unibilium](https://github.com/neovim/unibilium/),
but it also supports a built-in, standard mode which does not use terminfo at all.
(A lot of modern software just hardcodes the sequences.)

The other important module at Crysterm's core is [event_handler](https://github.com/crystallabs/event_handler).
through which all app events and input are routed (key presses, mouse actions, resize, focus, render lifecycle, and so on).

---

## 2. Getting started

### 2.1 Adding the dependency

Add Crysterm to your project's `shard.yml`:

```yaml
dependencies:
  crysterm:
    github: crystallabs/crysterm
    branch: master
```

### 2.2 A first program

```cr
require "crysterm"

alias C = Crysterm

screen = C::Screen.new

# Optionally pull the widget classes into the current namespace:
# include Crysterm::Widgets

hello = C::Widget::Box.new \
  name: "helloworld box",  # Symbolic name (for your own reference)
  top: "center",           # Integer, "50%", "50%+10", or "center"
  left: "center",
  width: 20,
  height: 5,
  content: "{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
  parse_tags: true,        # Interpret {…} tags in content (default: true)
  style: C::Style.new(fg: "yellow", bg: "blue", border: true)

screen.append hello

# Exit on `q` or Ctrl-Q. You can subscribe to a specific key event
# (C::Event::KeyPress::CtrlQ) or to all key presses and inspect the event.
screen.on(C::Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    screen.destroy
    exit
  end
end

# Run the main loop
screen.exec
```

A widget may be attached to its screen in either of two equivalent ways: by
passing `parent:` (or `screen:`) when constructing it, or by calling
`screen.append widget` afterwards. `append` is a convenience for the more
general `insert`; children are kept in the screen's (and each widget's)
`children` array.

> If you construct a widget without specifying any parent or screen, it
> attaches to a lazily-created global screen (`Screen.global`). This is
> convenient for quick scripts, but real applications should create and manage
> their own `Screen`.

### 2.3 What `exec` does

`Screen#exec` is the usual way to start an application. It:

1. Performs the first **render** of the screen (via `render`, which schedules a
   frame — see [§8](#8-rendering-and-drawing)).
2. Calls `listen`, which begins processing terminal input (keyboard, mouse,
   resize).
3. Blocks the main fiber (currently with a plain `sleep`) so the program keeps
   running.

Rendering itself happens on a dedicated background fiber, so `exec` does not run
a classic "draw-everything-each-iteration" loop. Instead, changes to widgets
*schedule* a frame, and the render fiber coalesces and paints them. This model
is described in [§3.3](#33-the-single-threaded-render-model) and
[§8](#8-rendering-and-drawing).

To tear a screen down, call `Screen#destroy`.

---

## 3. Architecture

### 3.1 Class hierarchy

- **`Screen`** is the top-level object. It represents the terminal it draws to,
  holding `input` (default `STDIN`), `output` (default `STDOUT`), and `error`
  (default `STDERR`) as properties. A screen owns the cell grid, the cursor,
  and the render loop.
- **`Widget`** is the base class for everything placed on a screen.
  `Widget::Box` is the generic rectangular widget; most other widgets
  (`List`, `Table`, `Form`, `TextArea`, `Log`, `ProgressBar`, `Image`, …)
  derive from it. Widgets can contain child widgets, forming a tree rooted at
  the screen.
- **Layout engines** (`Crysterm::Layout`) automatically arrange a container's
  children once installed via `widget.layout = ...` (see [§4.11](#411-layouts)).

### 3.2 The event model

`Screen` and `Widget` both `include EventHandler`, so they can emit events and
register listeners. Events are typed classes under `Crysterm::Event`, for
example `Event::KeyPress`, `Event::Mouse`, `Event::Resize`, `Event::Focus`,
`Event::PreRender`, and `Event::Rendered`.

Subscribe with `on`:

```cr
screen.on(C::Event::KeyPress) do |e|
  # e.char : Char?   — the character, if any
  # e.key  : Tput::Key? — a named key (e.g. Tput::Key::CtrlQ)
end
```

Key-press events are also available as specific subclasses — for instance
`Event::KeyPress::CtrlQ` — generated from the `Tput::Key` enum, so you can
listen for exactly one key instead of filtering inside a broader handler.

### 3.3 The single-threaded render model

Crysterm renders on **one fiber**, in the style of a GUI toolkit's main thread.
The render fiber (`render_loop`) is the sole owner of the cell buffer
(`@lines`) and the only place widgets are painted into it. Because the default
Crystal runtime is single-threaded and fibers are cooperative, the render fiber
and the input/handler fibers never truly run in parallel — they interleave only
at yield points — so **no locks** are needed on widget state.

Coordination uses a single capacity-1 channel as a coalescing *doorbell*:

- `schedule_render` rings the doorbell (non-blocking). If a frame is already
  pending, extra rings are dropped, which is what batches a burst of changes
  into a single frame.
- `render_loop` consumes the doorbell *before* rendering, so a change made
  while a render is in progress re-rings the doorbell and is picked up by the
  next frame (no lost updates).

If you ever compute something on another fiber (or a thread under
`-Dpreview_mt`) and need to apply it to widgets, use `post(&block)`: it queues
the closure to run *on the render fiber* just before the next frame, keeping all
widget mutation on that one fiber. `render` / `schedule_render` are themselves
safe to call from any fiber.

---

## 4. Positioning and sizing

For every widget Crysterm can get, set, and compute its position, size, and the
amount of inner space reserved for decorations (borders and padding). It can
also compute a widget's *minimal bounding box* — the smallest rectangle that
fits all of its content without scrolling.

A key idea: `left`, `top`, `right`, and `bottom` are **not** offsets from the
top-left (0, 0); each is an offset from its respective side. A widget with `top: 10`
and `bottom: 20` spans from 10
rows below the top edge to 20 rows above the bottom edge of its container. To
control the extent directly, pair a side with a size: `top` + `height`, or `left` +
`width`.

### 4.1 The coordinate model (xi/xl/yi/yl)

Internally, every widget's rendered rectangle is described by four absolute
coordinates, all measured from the screen's top-left (0, 0):

- `xi … xl` — the **column** range the widget occupies.
- `yi … yl` — the **row** range.

These are half-open ranges (`xi` inclusive, `xl` exclusive). A widget at
`left: 10, width: 50` therefore has `xi = 10` and `xl = 60` (i.e. columns
`10...60`). Because every widget is a rectangle, these four numbers are enough
to place and size any of them; they are stored on the widget's
`lpos` (last pos) after a render (see [§4.10](#410-last-rendered-position-and-the-get-flag)).

### 4.2 Four views of a widget's geometry

Crysterm exposes four related "views" of a widget's geometry, each with a
consistent set of accessors:

| Spec (as you set it) | Absolute (vs. screen) | Relative (vs. parent) | Inner offset (decoration) |
|----------------------|-----------------------|-----------------------|---------------------------|
| `left` / `left=`     | `aleft`               | `rleft`               | `ileft`                   |
| `top` / `top=`       | `atop`                | `rtop`                | `itop`                    |
| `right` / `right=`   | `aright`              | `rright`              | `iright`                  |
| `bottom` / `bottom=` | `abottom`             | `rbottom`             | `ibottom`                 |
| `width` / `width=`   | `awidth`              | —                     | `iwidth`                  |
| `height` / `height=` | `aheight`             | —                     | `iheight`                 |

- **Spec** methods (`left`, `top`, `width`, …) return *exactly what you set* —
  the raw user value, which may be an integer, a string such as `"50%+2"`, or a
  keyword such as `"center"`. They do not compute anything.
- **Absolute** methods (`aleft`, `awidth`, …) return computed integers measured
  from the screen corner.
- **Relative** methods (`rleft`, …) return computed integers measured from the
  parent widget's corner (or the screen, for a top-level widget).
- **Inner** methods (`ileft`, `iwidth`, …) return the *amount* of decoration on
  the inside (or summed across two sides), that is, they are not a position. See
  [§4.7](#47-inner-content-offsets).

### 4.3 Specifying position and size

A position or size value can be:

- **An integer** (e.g. `10`) — used directly.
- **`nil`** (the default for size) — auto-calculated to the largest space that
  fits (see [§4.6](#46-size)).
- **A percentage string** of the parent's corresponding dimension. Several
  forms are accepted:
  - `"50%"` — 50% of the parent.
  - `"50%+5"` / `"100%-1"` — a percentage plus or minus a fixed offset.
  - Fractional percentages such as `"33.5%"` are accepted as well.
- **`"half"`** — shorthand for `"50%"` (half of the parent, *without*
  centering).
- **`"center"`** — for `left`/`top`: position the widget at 50% of the parent
  and then shift it back by half the widget's own size, so it ends up centered.
  Concretely the position is computed as the 50% point *minus* `awidth // 2`
  (or `aheight // 2`). For this to center correctly the widget needs a defined
  size; for auto-sized/resizable widgets the centering is reapplied against the
  final (shrunken) size.

Percentages are taken against the parent's *whole* corresponding dimension, not
the space left over after decorations or after the widget's own offset. Two
consequences worth remembering:

- `top: 10, height: "100%"` makes the widget extend 10 rows past the bottom,
  because `"100%"` is the full parent height, independent of `top`. Use
  `height: "100%-10"`.
- A child with `height: "100%"` inside a bordered parent is two rows too tall
  (one for each of the parent's top and bottom border rows), because the
  percentage ignores the parent's decorations. Use `height: "100%-2"`.

The percentage/offset parsing is performed by `Widget.dimension`.

### 4.4 Relative position

`rleft`, `rtop`, `rright`, and `rbottom` are **computed** offsets relative to
the parent (or the screen, for a top-level widget). They are simple differences
of absolute coordinates:

```
rleft   = self.aleft   - parent.aleft
rtop    = self.atop    - parent.atop
rright  = self.aright  - parent.aright
rbottom = self.abottom - parent.abottom
```

(`left`/`top`/`right`/`bottom`, by contrast, return your raw values, as mentioned.
See [§4.2](#42-four-views-of-a-widgets-geometry).)

### 4.5 Absolute position

`aleft`, `atop`, `aright`, and `abottom` return computed integer coordinates
measured from the screen corner.
All of these getters take an optional `get` flag (default `false`) described in
[§4.10](#410-last-rendered-position-and-the-get-flag). They return values that
respect the widget's desired `left/top/right/bottom` and are offset from the
parent by the parent's inner (decoration) thickness.

They are also setters. The corresponding setters accept the same flexible
forms as the Spec setters; in particular `aleft=` and `atop=` also accept
`"center"` and percentage strings, which are resolved against the screen's
dimensions before being stored.

### 4.6 Size

`awidth` and `aheight` resolve the widget's size:

- If `width`/`height` is an **integer**, it is returned as-is.
- If it is a **string**, it is treated as a percentage of the parent (with
  `"half"` mapped to `"50%"`) and resolved to an integer.
- If it is **`nil`**, the size is computed as the largest space that fits,
  taking into account the parent's size, the parent's inner decoration
  thickness, and the widget's own `left/top/right/bottom`.

A `nil` size is therefore very different from `"100%"`. `"100%"` is a direct
percentage of the parent and ignores decorations and offsets, whereas `nil`
yields the largest size that actually fits *after* accounting for them. (When
`left`/`top` is `"center"`, a `nil`-sized widget is first sized to 50% of the
parent and then centered.)

### 4.7 Inner content offsets

The "i" accessors describe how much space decorations consume on each side —
they report *thickness*, not position:

- `ileft`, `itop`, `iright`, `ibottom` — for one side, the border thickness on
  that side plus the padding on that side.
- `iwidth`, `iheight` — the sums across the two horizontal or two vertical
  sides (left+right, top+bottom).

For example, a widget with a 1-cell border, 2 cells of top padding, and 3 cells
of bottom padding has `iheight = 1 + 2 + 3 + 1 = 7`. Border and padding render
*inside* the widget's width/height, so larger inner offsets mean less room for
content. (Shadow is the exception — it is cast *outside* the widget and does
not reduce inner space; see [§5.3](#53-shadow).)

In Crysterm a border can be more than one cell thick and can differ per side, so
the per-side `i` value is `border.<side> + padding.<side>` for whatever those
values are — there is no fixed "0 or 1" border assumption.

### 4.8 Resizable widgets

Setting `resizable = true` makes a widget render in the *minimal box* needed to
hold its content and children (it can grow from there). When a widget is
resizable, `_get_coords` calls `_minimal_rectangle`, which computes the bounding
box from the content and the children's own coordinates. Children anchored to
the right or bottom are handled specially so they don't inflate the parent's
computed size.

Minimal-size calculation is based on *actual content*; there is currently no way
to specify a programmer-defined minimum or maximum size, nor to grow/shrink
disproportionately on resize.

### 4.9 Overflow and clipping

A widget's `overflow` property controls what happens when it (or its children)
exceed the available rectangle. The `Overflow` modes are:

- `Ignore` — render unchanged; anything past the edge is simply not visible
  (the default).
- `Hidden` — clip children to this widget's rectangle, like CSS
  `overflow: hidden`, even if the widget is not scrollable.
- `ShrinkWidget` — make the widget smaller so it fits.
- `SkipWidget` — do not render the offending widget.
- `StopRendering` — end the render cycle, leaving the current and remaining
  widgets unrendered.
- `MoveWidget` — move the widget so it no longer overflows, when possible (handy
  for auto-completion popups and similar).

Scrollable ancestors and `Hidden` ancestors both clip their descendants; the
position code walks up to the nearest clipping ancestor and intersects against
it, setting per-side `no_left` / `no_top` / `no_right` / `no_bottom` flags on
the result for the parts that fall outside.

### 4.10 Last rendered position, and the `get` flag

When a widget is rendered, its absolute coordinates are stored in `lpos`
("last position"), an `LPos` object carrying `xi/xl/yi/yl` plus lazily-computed
cached copies of the `a*` and `i*` values and a `renders` counter. Because the
parent is always rendered before its children, a child can rely on the parent's
`lpos` being current.

This is why the position getters take a `get` flag:

- `get == false` (the default for ordinary position queries) computes against
  the live parent widget.
- `get == true` uses the parent's `lpos` instead of recomputing it. If the
  parent's cached `a*` values are not yet filled in, they are computed once from
  the screen dimensions and the stored `xi/xl/yi/yl`, then reused. This is more
  accurate during rendering because it reflects effects like content shrinkage
  that a fresh recomputation might miss.

`LPos` is currently a class (heap object); it could *almost* be a struct.

### 4.11 Layouts

A layout engine is a strategy object (under the `Crysterm::Layout` namespace,
in `src/layout/`) installed on any container widget — it is **not** itself a
widget (cf. Qt's `QLayout`). The container owns its rectangle, border and
padding; the layout only positions the children inside it:

```crystal
box = Widget::Box.new parent: screen, width: 40, height: 10,
  layout: Layout::HBox.new(gap: 1)
Widget::Box.new parent: box, width: 8   # fixed
Widget::Box.new parent: box             # flexes to fill the rest
```

The engines that ship today:

- `Layout::Grid` — uniform, table-like rows and columns.
- `Layout::Masonry` — masonry-like inline flow of variably-sized children.
- `Layout::HBox` / `Layout::VBox` — Qt-style single-axis boxes; children with no
  explicit main-axis size share the leftover space equally, and are stretched to
  fill the cross axis.

The table widgets (`Widget::Table`, `Widget::ListTable`) instead mix in the
`TableLayout` *content* layout, which lays out cell text within the widget's own
content rather than arranging child widgets.

Adding a new arrangement strategy is small: subclass `Crysterm::Layout` (or
`Layout::Flow` for a row-wrapping engine) and implement `#place`.

---

## 5. Decorations

Decorations are the visual extras around or attached to a widget: borders,
padding, shadow, and labels. Borders and padding render *inside* the widget's
width/height (reducing content space); shadow renders *outside*.

In Crysterm, border, padding, and shadow all live on the widget's **`Style`**
(`style.border`, `style.padding`, `style.shadow`) — there is no separate
`border`/`padding`/`shadow` property directly on the widget. (The boolean
*toggles* `scrollbar` and `track`, which control whether those elements are
shown at all, are widget-level properties; their *appearance* is configured via
`style.scrollbar` / `style.track`.)

### 5.1 Borders

A border is described by a `Border` object at `style.border`. Its main
properties:

- `type` — `BorderType::Line` (the default) or `BorderType::Bg`.
  - `Line` draws box-drawing characters (`│ ─ ┌ ┐ └ ┘` …, ACS or Unicode),
    including correct corner glyphs and optional docking to neighboring borders.
  - `Bg` fills the border cells with `char` (default a space), typically over a
    background color — a solid-block style border.
- `char` — the fill character used for a `Bg` border (default `' '`).
- `fg`, `bg` — border colors.
- `left`, `top`, `right`, `bottom` — the thickness on each side, in cells
  (default `1` each). Setting a side to `0` removes the border on that side.
- `bold`, `underline`, `blink`, `inverse`, `visible` — text attributes applied
  to the border (these exist so the border can be styled like any other
  element).

A few behaviors to keep in mind:

- **Per-side borders.** Each side's thickness is independent. A border is "on"
  for a side when that side's value is greater than 0.
- **Thickness > 1.** A side thicker than one cell currently reserves that much
  space (reducing content area accordingly, like padding), but the line glyphs
  are still drawn only in the outermost row/column — it does not yet draw nested
  or repeated border lines.
- **Border + scrollbar.** When a widget has a scrollbar, it normally renders in
  the rightmost content column. With a border present it moves one column
  inward. If the scrollbar's style has `ignore_border?` set, it instead renders
  *in* the border column, reusing that column.
- **Docking.** When the screen has `dock_borders` enabled, adjacent line borders
  are joined at the points where they meet — straight runs and the appropriate
  junction glyphs (`┬ ┴ ├ ┤ ┼`) are chosen automatically for a more elegant look.
  The screen's
  `dock_contrast` setting (`DontDock` / `Blend` / `Ignore`) governs what happens
  when the borders being joined have different colors or attributes. Option `blend`
  is particularly interesting as it smoothens the color difference.

### 5.2 Padding

Padding is empty space reserved on the inside of a widget, configured via
`style.padding` (a `Padding` object). Like borders it can be set per side
(`left`, `top`, `right`, `bottom`) and it reduces the space available for
content. Whether a widget has any padding at all is checked with
`style.padding.any?`, which gates the padding-aware code paths during
rendering.

### 5.3 Shadow

A shadow is configured via `style.shadow` (a `Shadow` object). Each of the four
sides can be enabled independently and given its own depth, and the shadow's
transparency is controlled by an `alpha` value (a `Float64`). The shadow is
drawn by blending the cells it covers toward darkness rather than overwriting
them, so whatever is underneath shows through, depending on the shadow's alpha
value.

Because each side is independent, the apparent direction of the light source
follows whichever sides you enable, rather than being fixed. Shadow is cast
*outside* the widget's width/height and therefore does not reduce the inner
content area.

### 5.4 Labels

A label is a short caption attached to a widget — the equivalent of a panel or
frame title in other toolkits. In Crysterm a label can be attached to *any*
widget, and it sits on the widget's first row, aligned left or right.

When you supply a label as text, Crysterm internally creates a `Widget::Box` to
hold it and stores it in the widget's `_label` property; you can then manipulate
that box afterward. The label subscribes to events on its parent (e.g.
`Event::Resize`, `Event::Scroll`) so it can reposition and redraw itself as the
parent changes — for example, a right-aligned label travels as the widget is
resized.

---

## 6. Styling

Just about everything visual about a widget lives in its `Style`. The long-term
goal is that an entire application's look could be described by a small set of
`Style`/`Styles` objects, serializable to a file (JSON, YAML, …) for theming.
Saving/loading and a formal theme format are not implemented yet, but the data
model is already organized around that idea.

Work in progress is to make the complete styling CSS-driven, but this is not
yet in the repository.

### 6.1 Style and the active style

Every widget has a `style` accessor that returns a `Style`. You may set a
specific style explicitly (`style=`); if you don't, the effective style is
selected from the widget's state-specific styles (see below). Setting `fg`,
`bg`, attributes, `border:`, etc. on a widget's `Style` controls how it renders.

Because `style` may be a *reference* into the widget's state styles, editing the
object you get back edits the definition of whatever state is currently active —
keep that in mind when mutating a style in place.

### 6.2 Widget states and `Styles`

A widget can be in different **states**, tracked by its `state`
(`WidgetState`). Crysterm models the states:

- `normal`
- `focused`
- `selected`
- `hovered`
- `blurred`
- `disabled`

The per-state styles are held in a `Styles` container on the widget
(`styles : Styles`). The active `style` is chosen from this container based on
the current state. `normal` is always present (`normal = Style.new`); the other
states default to `normal` when not explicitly defined, so you only set the
states you care about. (For example, if a widget is `focused` but no focused
style was defined, it renders with `normal`.)

### 6.3 Sub-element styles

Beyond states, a `Style` also carries styles for a widget's **sub-elements**, so
you can style each part separately. The sub-element styles are:

- `border`
- `scrollbar`
- `track`
- `bar`
- `item`
- `header`
- `cell`
- `label`
- `prefix`

Most sub-element styles are nilable and **default to the main style** when not
set (internally, `@sub || self`), so an unstyled scrollbar simply inherits the
widget's colors. `border` is special: it returns a `Border` object (carrying the
structural properties from [§5.1](#51-borders) as well as styling). `label` is
also special: it defaults to a *fresh, empty* `Style` rather than inheriting the
parent style.

### 6.4 Defaults

There is a shared default at the `Styles` level: `Styles.default` produces the
baseline `Styles` (derived from a single `Styles::DEFAULT` template) that a
widget uses when you don't supply your own. This is the hook through which a
global default appearance is provided. (Note the default lives on `Styles`, the
per-state container — not on `Style`.)

---

## 7. Text, attributes, and colors

### 7.1 Tags

Widget content may contain inline **tags** — Crysterm's markup for colors,
attributes, and alignment — written with curly braces, e.g.:

```
{light-blue-fg}Text in light blue{/light-blue-fg}
```

Tags are interpreted when the widget's `parse_tags` is enabled (the default).
Internally, `_parse_tags` converts them into the corresponding terminal escape
(SGR) sequences before the content is laid out.

Three helpers in `Crysterm::Helpers` work with tags:

- `escape(text)` — protect literal braces by replacing `{` and `}` with the
  `{open}` and `{close}` tags, so existing `{...}` in a string is not
  interpreted.
- `strip_tags(text)` — remove tags (and any embedded SGR sequences) and strip
  surrounding whitespace.
- `clean_tags(text)` — remove tags and embedded SGR sequences without the extra
  trim.

### 7.2 Attribute and alignment tags

The supported tags are:

- **Alignment:** `{center}`, `{left}`, `{right}`.
- **Attributes:** `{normal}` (alias `{default}`), `{bold}`,
  `{underline}` (aliases `{underlined}`, `{ul}`), `{blink}`, `{inverse}`,
  `{invisible}`, and the strike-through family `{strikethrough}` (aliases
  `{strike}`, `{crossed}`, `{crossed_out}`).
- **Colors:** `{COLOR-fg}` and `{COLOR-bg}` (see [§7.3](#73-colors)).
- **Literals:** `{open}` and `{close}` for a literal `{` and `}`.
- **Close-all:** `{/}` closes all currently-open tags (it resets to the normal
  attribute).

A closing tag mirrors its opener with a leading slash, e.g.
`{bold}…{/bold}` or `{red-fg}…{/red-fg}`.

### 7.3 Colors

A color in a tag may be given three ways:

- **By name** — `{red-fg}`, `{blue-bg}`, etc. The recognized names come from the
  `term_colors` shard and cover the basic eight (`black`, `red`, `green`,
  `yellow`, `blue`, `magenta`, `cyan`, `white`), their `light-` and `bright-`
  variants, the `gray`/`grey` spellings (including `light-`/`bright-` greys),
  and the special markers `default` / `normal` / `fg` / `bg` (which map to the
  terminal's default color).
- **By palette index** — `{ID-fg}`, e.g. a number in `0..255` for the 256-color
  palette.
- **By RGB hex** — `{#RRGGBB-fg}` (and a short `#RGB` form), using the full
  24-bit palette. **This is the recommended way to specify colors:** Crysterm's
  native color space is TrueColor, and it automatically reduces colors to 256,
  16, 8, or 2 as needed for the terminal in use.

You can also embed raw escape sequences yourself, or use Crystal's `Colorize`
module; Crysterm interoperates with content styled that way.

### 7.4 Color reduction and the packed attribute

Internally, a single color is a logical `Int32`: `-1` means "terminal default",
and `0x000000`..`0xFFFFFF` is a 24-bit RGB value. A cell's full appearance — its
flags (bold/underline/…) and its foreground and background colors — is packed
into a single `Int64` *attribute* (`Attr`), with wide color fields for fg and bg
and the remaining bits for flags.

Colors are kept at full fidelity in memory and reduced only at **output time**,
when the SGR sequence is generated: TrueColor terminals get `38;2;r;g;b`,
256-color terminals get `38;5;index`, and lower terminals get the nearest 16/8
color. The number of colors the terminal supports is queried once per frame and
drives this reduction.

### 7.5 Putting it together

Because tags compile down to SGR sequences and those are parsed back into packed
attributes during rendering, you can freely mix tags, raw escapes, and
`Colorize` output in the same content string; they all end up as the same packed
cell attributes.

---

## 8. Rendering and drawing

Crysterm separates **rendering** (computing the desired screen state in memory)
from **drawing** (emitting the minimal terminal output to realize it).

### 8.1 The pipeline

`Screen#render` (usually invoked indirectly) schedules a frame. When the frame
runs, `_render`:

1. Emits `Event::PreRender`.
2. Clears the in-memory cell buffer (`@lines`) back to the default cell. Widgets
   are repainted from scratch every frame, so the buffer always starts clean.
   This also makes alpha/transparency blending correct (each frame blends over
   the base, not over the previous frame's already-blended result) and removes
   the need to manually clear spots a widget has vacated.
3. Walks the screen's direct children in order and calls `render` on each, which
   recursively renders their children. Each widget paints itself into `@lines`.
4. Optionally docks borders (when `dock_borders` is on).
5. Calls **`draw`**, which compares the new buffer to what is on the terminal and
   emits only the differences.
6. Emits `Event::Rendered`.

Because children are painted in order and later widgets overwrite earlier cells,
this is effectively a [painter's algorithm](https://en.wikipedia.org/wiki/Painter%27s_algorithm).

### 8.2 Damage tracking

`draw` is the differential part. The screen keeps two grids: `@lines` (the new,
desired state) and `@olines` (what is currently on the terminal). For each row,
if nothing changed (the row is not "dirty") it is skipped entirely. Within a
changed row, each cell is compared against `@olines`; unchanged cells emit
nothing, and runs of unchanged cells are skipped with a single cursor move
rather than redrawn. Only actual changes ("damage") produce output, which keeps
the escape-sequence stream small.

### 8.3 Optimizations

Two optional terminal-level optimizations are available via the screen's
`optimization` property, an `OptimizationFlag` set:

- **`BCE` (back-color-erase)** — uses the terminal's ability to clear to
  end-of-line in the current background color, replacing long runs of spaces
  with a short erase sequence.
- **`FastCSR` / `SmartCSR` (change-scroll-region)** — uses the terminal's scroll
  region to move existing content for scroll-like updates instead of repainting
  it.

These default to **off** (`OptimizationFlag::None`): some terminal emulators
(e.g. gnome-terminal) do not always render them correctly, so they are opt-in.

### 8.4 Frame coalescing and the interval

Rendering is throttled and coalesced. `interval` is the minimum allowed spacing
between frames, defaulting to `1/29` of a second — about 29 fps.
The render loop parks on the
coalescing doorbell described in [§3.3](#33-the-single-threaded-render-model);
the first request after an idle period renders immediately, while back-to-back
requests are spaced out to honor `interval`. As a result you can call `render`
from anywhere at any time — all the changes accumulated since the last frame are
painted together in one pass, and isolated updates are not delayed.

---

## 9. The cursor

The cursor belongs to the `Screen` and is available as `Screen#cursor`. It is a
small object (`Screen::Cursor`, extending `Tput::Namespace::Cursor`) holding the
cursor's shape, blink state, and a `style` (a `Style` used for the cursor's
color and glyph; its default `char` is `▮`).

Crysterm supports two kinds of cursor:

- **Hardware cursor** — the terminal's own cursor. Showing, hiding, shaping, and
  coloring it are delegated to the terminal via `Tput`.
- **Artificial cursor** — a cursor Crysterm draws itself, by painting a synthetic
  glyph into the rendered buffer at the cursor position. This is useful when the
  real cursor cannot be styled the way you want. It is active when
  `cursor.artificial?` is true.

The shape is a `Tput::CursorShape` and can be `Block` (alias `Box`),
`Underline` (aliases `Underscore`, `HLine`, `HBar`), or `Line` (aliases
`VLine`, `VBar`). The shape names/aliases are defined in the `Tput` library.

The main operations, all on `Screen`:

- `cursor_shape(shape = Tput::CursorShape::Block, blink = false)` — set the shape
  and whether it blinks.
- `cursor_color(color = nil)` — set the cursor's color.
- `show_cursor` / `hide_cursor` — show or hide the cursor. For a hardware cursor
  these call into `Tput`; for an artificial cursor they toggle its hidden flag
  and re-render.
- `apply_cursor` — push the current cursor settings (shape, blink, color) to the
  display; called automatically during rendering.
- `cursor_reset` — disable the artificial cursor (if any) and reset the hardware
  cursor to a steady, non-blinking block.

When the artificial cursor is active, its appearance is computed in
`_artificial_cursor_attr` and drawn during `Screen#draw` at the terminal's
current cursor position: a `Line` shape renders as a `│` glyph, `Underline` adds
the underline attribute, `Block` inverts the cell, and `None` falls back to the
cursor's own `style` (including a custom `char` and colors).

> The cursor currently lives on the `Screen`; moving it onto `Widget` is planned
> so that cursor can vary per-widget.

---

## 10. Performance and FPS

During development Crysterm displays a frames-per-second readout. This is
controlled by `show_fps`, a `Tput::Point?` giving the screen position of the
readout (`nil` disables it). It is **enabled by default** while the library is
under active development, positioned at the bottom-left.

The readout looks like:

```
R/D/FPS: 761/191/153 (782/248/187)
```

The three numbers are, for the current frame:

- **R** — estimated *renderings* per second (1 by time spent in the render phase).
- **D** — estimated *drawings* per second (1 by time spent in the draw phase).
- **FPS** — total/combined *frames* per second that would be achievable.

Higher is better (i.e. less time is needed for each frame).

When `show_avg` is on, the values in parentheses are running averages over the
last 30 frames (each tracked by a small fixed-size averaging ring,
`Average.new 30`).

Because the render+draw cycle is capped at roughly `interval` frames per second
(~29 by default), the reported FPS staying comfortably above that ceiling is the
sign of headroom; if it drops to or below the cap, frames may be skipped.

For library-internal benchmarking, the project measures memory *allocations* rather
than wall-clock `ips`. The
render/draw hot path is written to avoid accumulating per-frame memory — for example,
per-cell character handling, SGR scanning, color emission, and content indexing
all avoid memory allocation, which results in less GC runs and less
jitter in a TUI. See `benchmarks/render-hotpath.cr`.

---

## 11. Configuration

Crysterm has a single, global configuration registry, `Crysterm::Config`, that
holds every tunable the framework exposes — and any your app adds. Each option
has four synchronized surfaces and remembers where its current value came from.

By default nothing is read from the outside: every option keeps its registered
default, so programs behave exactly as if the registry weren't there. You opt in
to external sources explicitly.

### Surfaces

For an option with key `screen.resize_interval`:

| Surface | Form |
|---|---|
| Config key | `screen.resize_interval` (YAML: `screen: { resize_interval: 0.5 }`) |
| Environment variable | `CRYSTERM_SCREEN_RESIZE_INTERVAL` |
| Command-line option | `--screen-resize-interval=0.5` |
| Runtime | `Crysterm::Config.screen_resize_interval` (typed accessor) |

Reading and writing at runtime use the typed accessor — the option key with
dots turned into underscores — so there's no string key or type argument, and
it's a cached read (no registry lookup):

```crystal
Crysterm::Config.screen_resize_interval        # => Time::Span
Crysterm::Config.screen_resize_interval = 0.5.seconds
```

(`Crysterm::Config.get("screen.resize_interval", Time::Span)` and `.set` also
exist for fully dynamic, string-keyed access — that's what the loaders use.)

### Opting in

```crystal
require "crysterm"

# Loads (lowest→highest precedence): config file, env vars, command-line flags.
Crysterm.configure!                       # auto-loads ~/.config/crysterm/config.yml if present, then env + CLI
Crysterm.configure! "/etc/myapp.yml"      # explicit file + env + CLI
Crysterm.configure! file: ""              # skip file loading; env + CLI only
```

With no `file:` argument, `configure!` looks for `$XDG_CONFIG_HOME/crysterm/config.yml`
(falling back to `~/.config/crysterm/config.yml`) and loads it when it exists —
see `Crysterm::Config.default_config_path`.

Precedence, low to high: **default < config file < env var < command-line <
runtime assignment**. A lower-precedence source never overrides a value already
set by a higher one.

`--config FILE` (load an extra file) and `--dump-config [FORMAT]` (dump and
exit) are handled automatically once you call `configure!` / `Config.load_args`.

### Adding your own options

Reopen `Superconf` and use `option` (anywhere after `require "crysterm"`).
`Crysterm::Config` is an alias of the shared `Superconf` registry, so you declare
options on `Superconf` (you can't reopen an alias) but read them through either
name. The value type is inferred from the default; built-in parsing covers
`Bool`, `Int32`, `Int64`, `Float64`, `String`, `Char`, `Time::Span`, and any
`Enum` (including `@[Flags]`). For other types pass a `parse:` proc.

```crystal
module Superconf
  option "myapp.refresh", 1.second, description: "Data refresh interval"
end

# CRYSTERM_MYAPP_REFRESH / --myapp-refresh / myapp.refresh all work, the option
# appears in every dump (next to crysterm's and tput's options), and you get a
# typed accessor for free:
interval = Crysterm::Config.myapp_refresh   # => Time::Span
```

`Crysterm::Config.register` (without the accessors) remains available for
options whose keys are only known at runtime.

#### Validating values

Pass a `validate:` predicate to reject absurd values. It runs against every
value that takes effect — from env, CLI, a config file, or a runtime assignment
— and against the default at declaration time. A failing value is rejected with
a `Crysterm::Config::Error` and never reaches the rest of the app:

```crystal
module Superconf
  option "myapp.workers", 4,
    description: "Worker count",
    validate: ->(n : Int32) { n > 0 }
end

# CRYSTERM_MYAPP_WORKERS=0 myapp   →  Config::Error: invalid value 0 for option myapp.workers
```

Rescue `Crysterm::Config::Error` to handle all config problems (unknown key,
unparseable value, or failed validation) in one place.

### Dumping

`Crysterm::Config.dump(io, format)` (or `--dump-config [FORMAT]`) emits:

* `yaml` (default) and `json` — valid, **re-loadable** config files;
* `env` — a sourceable shell script of `export CRYSTERM_…='value'` lines
  (`eval "$(myapp --dump-config=env)"` re-applies them via `load_env`);
* `pretty` — an aligned table that also shows each value's **source**;
* `report` — rich JSON with full metadata (value, source, default, env, CLI,
  description) for every option, analogous to `tput`'s `--json` detections.

```
$ CRYSTERM_SCREEN_RESIZE_INTERVAL=0.5 myapp --render-optimization=smart_csr,bce --dump-config=pretty
OPTION                  VALUE           SOURCE
----------------------  --------------  ------
render.optimization     SmartCSR | BCE  command line (--render-optimization)
screen.resize_interval  0.5             env CRYSTERM_SCREEN_RESIZE_INTERVAL="0.5"
...
```

See `examples/config-dump.cr` for a runnable example.

## 12. Differences from Blessed

**Positioning and sizing**

- In Blessed the user-set values live in `widget.position.*` and `left`/`top`/…
  read from there. In Crysterm the Spec getters `left`/`top`/`right`/`bottom`
  *are* the raw user values, the absolute values are `aleft`/`atop`/…, and the
  relative values are `rleft`/`rtop`/… (computed as the difference of absolute
  positions). The accessor table in [§4.2](#42-four-views-of-a-widgets-geometry)
  is the streamlined Crysterm interface.
- Blessed's "shrink" option is called **`resizable`** in Crysterm, reflecting
  that it can grow as well as shrink.

**Decorations**

- In Blessed, border/padding/shadow are reached partly through a `border`
  property and partly through `style`. In Crysterm they live entirely on the
  `Style`: `style.border`, `style.padding`, `style.shadow`. There is no `border`
  property on the widget.
- The default border type is `Line` in Crysterm (Blessed defaults to a
  background/`bg` border). There is no `ascii` border alias.
- Blessed's border is on or of (1 or 0 pixels) on all four sides (much of its code
  just checks whether `border` is truthy). Crysterm supports independent
  per-side borders, per-side thickness greater than 1 (currently drawn only in
  the outermost cell), and border text attributes (`bold`, `underline`, …).
- Blessed's shadow is fixed: 1 cell high, 2 cells wide, top-left light source,
  50% transparent. Crysterm's shadow can be placed per side, with per-side
  depth, adjustable `alpha`, and a light direction that follows the enabled
  sides.
- Blessed creates a "label" on a widget as an internal text box. Crysterm does
  the same with a generic `Widget::Box` (stored in `_label`) but, in principle,
  allows any widget to serve as a label.

**Styling**

- Blessed's styling is spread across several places; Crysterm consolidates
  everything style-related under `Widget#style`, with per-state styles in a
  `Styles` container and per-sub-element styles inside each `Style`. The shared
  default is `Styles.default` (note: on the `Styles` container, not a
  `Style.default`).
