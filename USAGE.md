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
one or more `Window`s (each backed by a `Screen`, the terminal device),
a hierarchical tree of `Widget`s placed on them,
and `Style` objects for visual look.

Widgets are placed in various types of auto-arranging layouts or positioned
with a flexible scheme (absolute integers, percentages,
or keywords such as `"center"`), decorated with borders/padding/shadow/frame, and
filled with content that may contain inline markup ("tags") for colors and
attributes. The window renders the whole tree into an off-screen cell buffer
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

# A `Window` is the surface your widgets live on. (A `Screen` is the physical
# terminal *device* behind it — see §3.1; you rarely construct one yourself.)
window = C::Window.new title: "hello"

# Optionally pull the widget classes into the current namespace:
# include Crysterm::Widgets

hello = C::Widget::Box.new \
  parent: window,          # The surface this widget belongs to
  name: "helloworld box",  # Symbolic name (for your own reference)
  top: "center",           # Integer, "50%", "50%+10", or "center"
  left: "center",
  width: 20,
  height: 5,
  content: "{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
  parse_tags: true,        # Interpret {…} tags in content (default: false)
  style: C::Style.new(fg: "yellow", bg: "blue", border: true)

# `q` / Ctrl-Q already quit by default (see `Window#default_quit_keys?`), so
# nothing else is needed here. To handle keys yourself, subscribe to a specific
# key event (C::Event::KeyPress::CtrlQ) or to all of them and inspect the event:
#
#   window.on(C::Event::KeyPress) { |e| ... }

# Run the main loop
window.exec
```

A widget may be attached to its window in either of two equivalent ways: by
passing `parent:` when constructing it, or by calling `window.append widget`
afterwards. `append` is a convenience for the more general `insert`; children
are kept in the window's (and each widget's) `children` array.

> If you construct a widget without specifying any parent, it attaches to a
> lazily-created global window. This is convenient for quick scripts, but real
> applications should create and manage their own `Window`.

### 2.3 What `exec` does

`Window#exec` is the usual way to start an application. It:

1. Performs the first **render** of the window (via `update`, which schedules a
   frame — see [§8](#8-rendering-and-drawing)).
2. Calls `listen`, which begins processing terminal input (keyboard, mouse,
   resize).
3. Blocks the main fiber (currently with a plain `sleep`) so the program keeps
   running.

Rendering happens on a dedicated background fiber, so `exec` does not run a
classic "draw-everything-each-iteration" loop. Instead, **changing a widget
schedules the frame that paints it**, and the render fiber coalesces those
requests: a burst of changes collapses into one repaint, capped at ~60fps. So
application code sets state and stops there —

```cr
status.content = "Saved"   # repaints; no `window.update` needed
panel.hide                 # ditto — and its layout slot is released
```

— and there is no need to call `window.update` after a mutation. Everything
routed through `Widget#update` does this: content, geometry
(`left`/`top`/`width`/`height`), visibility (`show`/`hide`), focus and widget
state. An idle UI produces no frames at all.

You still call a render explicitly in two cases:

* **`window.update`** — to request a frame for a change the setters can't see,
  such as mutating a `Style` object in place (`widget.style.bg = "red"`). Or
  call `widget.update` after it, which is the same thing plus damage
  tracking.
* **`window.repaint`** — to paint *synchronously, right now*, when the next line
  depends on the result. Two situations need it: reading layout-assigned
  geometry (a layout engine only assigns a child's position and size during a
  frame, so it isn't known before one), and driving an animation from a blocking
  loop (the coalescing scheduler would collapse every step into a single frame).
  See [§4.11](#411-layouts).

This model is described in [§3.3](#33-the-single-threaded-render-model) and
[§8](#8-rendering-and-drawing).

To tear a window down, call `Window#destroy`.

---

## 3. Architecture

### 3.1 Class hierarchy

- **`Screen`** is the physical terminal *device* — the `QScreen` analogue. It
  owns everything tying Crysterm to one concrete tty: `input` (default `STDIN`),
  `output` (default `STDOUT`) and `error` (default `STDERR`), the `Tput`
  control-sequence generator, the device's cell size, and the output color
  depth. You rarely construct one yourself.
- **`Window`** is the *surface* your program draws on — the `QWindow` /
  top-level `QWidget` analogue, and the object you actually create. It owns the
  cell buffer, the widget-tree root, focus, damage tracking, the cursor, and the
  render loop. A `Window` *has-a* `Screen` and delegates device concerns to it;
  the split is what lets one application drive several ttys, and what lets a
  surface survive its device being rebuilt (detach/reattach).
- **`Application`** is optional: it groups the `Window`s one app drives. A
  single-window program can just call `Window#exec` (see [§2.3](#23-what-exec-does)).
- **`Widget`** is the base class for everything placed on a window.
  `Widget::Box` is the generic rectangular widget; most other widgets
  (`List`, `Table`, `Form`, `TextArea`, `Log`, `ProgressBar`, `Image`, …)
  derive from it. Widgets can contain child widgets, forming a tree rooted at
  the window.
- **Layout engines** (`Crysterm::Layout`) automatically arrange a container's
  children once installed via `widget.layout = ...` (see [§4.11](#411-layouts)).

### 3.2 The event model

`Window` and `Widget` both `include EventHandler`, so they can emit events and
register listeners. Events are typed classes under `Crysterm::Event`, for
example `Event::KeyPress`, `Event::Mouse`, `Event::Resize`, `Event::FocusIn`,
`Event::FocusOut`, `Event::PreRender`, and `Event::Rendered`.

Subscribe with `on`:

```cr
window.on(C::Event::KeyPress) do |e|
  # e.char : Char?   — the character, if any
  # e.key  : Tput::Key? — a named key (e.g. Tput::Key::CtrlQ)
end
```

Key-press events are also available as specific subclasses — for instance
`Event::KeyPress::CtrlQ` — generated from the `Tput::Key` enum, so you can
listen for exactly one key instead of filtering inside a broader handler.

#### Subscribing, disconnecting, and overriding

Three naming conventions divide the event surface, one per job:

- **`on(Event::X) { }` and the `on_<event>` sugar** (`button.on_clicked { }`,
  `edit.on_text_changed { |s| }`) **subscribe**: every registered block fires,
  and each call returns an `EventHandler::Subscription` — a self-contained
  handle whose `#off` disconnects exactly that handler:

  ```crystal
  sub = button.on_clicked { save }
  sub.off # disconnected; idempotent, safe to call twice
  ```

  The sugar exists for *every* event: declaring an event generates a matching
  `on_<event underscored>(&)` on every emitter (`w.on_resize { |e| }`,
  `w.on_focus_in { |e| }`, …), yielding the event object. A few widgets
  shadow theirs with a richer adapter that yields the payload instead
  (`on_toggled { |bool| }`, `on_value_changed { |v| }`,
  `on_text_changed { |s| }`, `on_current_index_changed { |i| }`). The
  generated per-key `Event::KeyPress::<member>` family is excluded —
  subscribe to those with `on(Event::KeyPress::CtrlQ) { }` (or `on_key`).
  To shorten the long event paths, `include Crysterm::Events` — the events
  sibling of `Crysterm::Widgets` — and write `on(Clicked)` directly.

  For several handlers torn down together, collect them in a
  `Crysterm::Subscriptions` bag (`subs.on(target, Event::X) { }` … `subs.off`);
  `subs.auto_dispose(widget) { }` ties the teardown to the widget's
  `Event::Destroy`.

- **`handle_<event>`** (`handle_key_press`, `handle_click`, …) is the
  **overridable slot** — the method the framework wires up and calls, Qt's
  `keyPressEvent()` analogue. Subclass and override these to change behavior
  (usually calling `super` for the parts you keep); never call them to
  subscribe.

- **`<name>_handler`** (`clock.stop_handler { }`, `menu.navigate_handler { }`)
  sets a **single overwritable callback** — one slot, where a second
  assignment replaces the first. The old `on_*` spellings of these have been
  removed: they looked like subscriptions but silently dropped the previous
  handler.

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

> **Do not use `async:` handlers.** The underlying `event_handler` shard
> offers `on(..., async: true)` (and a global `EventHandler.async=` switch)
> which `spawn`s each handler on its own fiber. Crysterm does not support
> this: handlers would leave the render fiber's interleaving model above, and
> the reactive layer's state is documented single-fiber. Route cross-fiber
> work through `post(&block)` below instead.

If you ever compute something on another fiber (or a thread under
`-Dpreview_mt`) and need to apply it to widgets, use `post(&block)`: it queues
the closure to run *on the render fiber* just before the next frame, keeping all
widget mutation on that one fiber. `update` / `schedule_render` are themselves
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
`lpos` (last pos) after a render (see [§4.10](#410-last-rendered-position-and-the-rendered-flag)).

### 4.2 Three views of a widget's geometry

Crysterm exposes three related "views" of a widget's geometry, plus the
decoration thicknesses, each with a consistent prefix:

| Spec (as you set it)          | Relative, resolved (vs. parent) | Absolute, resolved (vs. window) | Inner offset (decoration) |
|-------------------------------|---------------------------------|---------------------------------|---------------------------|
| `left` / `left=`              | `rleft`                         | `aleft`                         | `ileft`                   |
| `top` / `top=`                | `rtop`                          | `atop`                          | `itop`                    |
| `right` / `right=`            | `rright`                        | `aright`                        | `iright`                  |
| `bottom` / `bottom=`          | `rbottom`                       | `abottom`                       | `ibottom`                 |
| `width_spec` / `width=`       | —                               | `awidth` (= `width`)            | `ihorizontal`             |
| `height_spec` / `height=`     | —                               | `aheight` (= `height`)          | `ivertical`               |

- **Spec** methods (`left`, `top`, `width_spec`, …) return *exactly what you
  set* — the raw user value, which may be an integer, a `Dim`, a string such
  as `"50%+2"`, or `nil`. They do not compute anything.
- **Relative** methods (`rleft`, …) return computed integers in the *spec
  space*: each is the value its bare setter would need to reproduce the
  current placement, so `w.left = w.rleft` is a no-op. See
  [§4.4](#44-relative-position).
- **Absolute** methods (`aleft`, `awidth`, …) return computed integers measured
  from the window's top-left corner.
- **Inner** methods (`ileft`, `ihorizontal`, …) return the *amount* of
  decoration on the inside (or summed across the two sides of an axis) — a
  thickness, not a position. See [§4.7](#47-inner-content-offsets).

The prefix rule in one line: **bare position = your spec, `r*` = relative
resolved (round-trips through the bare setter), `a*` = absolute resolved.**
Sizes are the deliberate exception, matching how every Qt/CSS reader parses
`w.width`: **`width`/`height` return the resolved cells** (aliases of
`awidth`/`aheight`), and the raw specs live at `width_spec`/`height_spec`.
The setters take specs in both spellings (`w.width = "50%"` works), so
`w.width = w.width` round-trips for cell specs — writing back a resolved
value pins a percent/auto spec, the usual imperative trade.

On top of the scalar accessors sit the Qt-named value-object forms:

- `x` / `y` / `pos : Point` — aliases of `rleft`/`rtop` (Qt's `x()`, `y()`,
  `pos()`); `pos=`/`move` write back.
- `size : Size` — `(awidth, aheight)` bundled — i.e. `(width, height)`;
  `resize`/`size=` write back.
- `geometry : Rectangle` — the live parent-relative rectangle,
  `geometry.top_left == pos` (Qt's `geometry()`); `geometry=`/`set_geometry`
  write back, so `w.geometry = w.geometry` is a no-op. `rect` is the same box
  in the widget's own coordinates, `(0, 0, awidth, aheight)`.
- `absolute_geometry : Rectangle?` — the **last-rendered** box in absolute
  window coordinates (nil before the first render), after clipping/scroll;
  the value-type view of `rendered_geometry` ([§4.10](#410-last-rendered-position-and-the-rendered-flag)).

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
  - Viewport units — `"50vw"`, `"50vh"`, `"50vmin"`, `"50vmax"` — resolve
    against the *window* size regardless of nesting depth, like their CSS
    namesakes.
- **`"half"`** — shorthand for `"50%"` (half of the parent, *without*
  centering).
- **`"center"`** — for `left`/`top`: position the widget at 50% of the parent
  and then shift it back by half the widget's own size, so it ends up centered.
  Concretely the position is computed as the 50% point *minus* `awidth // 2`
  (or `aheight // 2`). For this to center correctly the widget needs a defined
  size; for auto-sized/`shrink_to_fit` widgets the centering is reapplied
  against the final (shrunken) size. (The constructor shorthands `center:`,
  `center_x:`, `center_y:` and `fill:` expand to these specs for you.)
- **A `Dim`** — the value type every string/symbol form parses into:
  `Dim.cells(10)`, `Dim.percent(50)`, `Dim.percent(50, -2)` (percent plus
  offset), `Dim.center(offset = 0)`, `Dim.vw(50)`/`.vh`/`.vmin`/`.vmax`.
  Strings and symbols are parsed to a `Dim` **once, at assignment** (by
  `Dim.from`/`Dim.parse`), so a malformed expression raises `ArgumentError`
  right at the setter instead of silently resolving to 0 every frame.

What a percentage is measured against differs by kind, matching CSS:

- A percentage **size** (`width: "50%"`) resolves against the parent's
  **content area** — the space inside its border and padding. So
  `height: "100%"` inside a bordered parent fits *exactly*; there is no need
  for the Blessed-style `"100%-2"` dance (which now produces a child two rows
  short).
- A percentage **position** (`left: "50%"`) resolves against the parent's
  **whole** dimension, and a near-anchored child is then placed relative to
  the content origin — `left: 0` sits just inside the border.
- The percentage is independent of the widget's own offset:
  `top: 10, height: "100%"` extends 10 rows past the bottom. Use
  `height: "100%-10"`, or leave `height: nil` (which subtracts the offsets;
  see [§4.6](#46-size)).

### 4.4 Relative position

`rleft`, `rtop`, `rright`, and `rbottom` are **computed** offsets in the *spec
space*: each returns the `Int32` its bare setter (`left=`/`top=`/…) would need
to reproduce the current resolved placement. That gives the prefix convention
its round-trip law:

```crystal
w.left = w.rleft        # no-op
w.move w.pos            # no-op
w.geometry = w.geometry # no-op; geometry.top_left == pos
```

Concretely they are offsets from the parent's *content* origin (inside its
border and padding) — exactly what the spec setters consume — with the
widget's own margin shift compensated on the near edges. `x`/`y`/`pos` are the
Qt-named aliases of `rleft`/`rtop`.

Two caveats, shared with Qt's imperative setters: writing a resolved value
back (`w.left = w.rleft`, `w.geometry = w.geometry`) keeps the position but
**pins** it — a percent/`center` spec becomes plain cells (reactivity to
parent resizes is dropped), and a far-anchored (`right:`/`bottom:`-only)
widget becomes near-anchored. The declarative specs remain the reactive path.

### 4.5 Absolute position

`aleft`, `atop`, `aright`, and `abottom` return computed integer coordinates
measured from the window's top-left corner. All of these getters take an
optional `rendered` flag (default `false`) described in
[§4.10](#410-last-rendered-position-and-the-rendered-flag). They return values
that respect the widget's `left/top/right/bottom` specs and are offset from
the parent by the parent's inner (decoration) thickness.

They are getters only — to change a position, write the specs (`left=`, …,
`move`, `set_geometry`). For the last-*rendered* absolute box (after
clipping/scroll) as a value object, see `absolute_geometry`
([§4.2](#42-three-views-of-a-widgets-geometry)).

### 4.6 Size

`awidth` and `aheight` resolve the widget's size in cells (`width`/`height`
are their Qt/CSS-reading aliases, and `size : Size` the bundle):

- If the spec (`width_spec`/`height_spec`) is an **integer**, it is returned
  as-is.
- If it is a **`Dim`/string percentage**, it resolves against the parent's
  *content area* (with `"half"` mapped to `"50%"`).
- If it is **`nil`**, the size is computed as the largest space that fits,
  taking into account the parent's content area and the widget's own
  `left/top/right/bottom` offsets (and, under a layout engine, whatever the
  engine assigned — see [§4.11](#411-layouts)).

`nil` differs from `"100%"` only in respecting the widget's own offsets: both
fill the parent's content area, but a `nil` size subtracts `left`/`top` (and
the widget's own margins) so the widget still fits, whereas `"100%"` keeps
its full extent regardless. (When `left`/`top` is `"center"`, a `nil`-sized
widget is first sized to 50% of the parent and then centered.)

The resolved size is clamped to the CSS-style **min/max constraints**
`min_width`/`max_width`/`min_height`/`max_height` (cells or percentages;
`min` wins a min>max conflict, per CSS; `minimum_size`/`maximum_size` are the
Qt-named `Size` bundles). And `box_sizing` selects which box a declared size
measures: the default `BorderBox` counts the whole on-screen extent (border
included — what TUI code expects), `ContentBox` opts into the CSS/Qt reading
where the frame is added *around* the declared content size.

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

### 4.8 Shrink-to-fit widgets and size hints

Setting `shrink_to_fit = true` makes a widget render in the *minimal box*
needed to hold its content and children (it can grow from there) — roughly
CSS `width: fit-content`. Only the axes left unset (`nil` `width_spec`/`height_spec`)
shrink; the bounding box is computed from the content and the children's own
coordinates, with right/bottom-anchored children handled specially so they
don't inflate the parent's computed size.

For a programmer-defined floor/ceiling, use the `min_width`/`max_width`/
`min_height`/`max_height` constraints ([§4.6](#46-size)). Related Qt-shaped
accessors:

- `size_hint : Size` — the widget's natural size (content extent plus frame
  insets; item views count their items). Virtual — a widget with a better
  notion overrides it.
- `minimum_size_hint : Size` — the smallest sensibly paintable size (the
  frame insets alone, in the base class). Advisory; the *enforced* floor is
  `min_width`/`min_height`.
- `adjust_size` — one-shot `resize(size_hint)`, bounded by the parent's
  content area (Qt's `adjustSize()`).

`shrink_to_fit` is self-sizing *outside* any layout engine. For a widget
arranged by one, the equivalent knob is a `Preferred` `size_policy` axis,
which sizes the slot to `size_hint` — see [§4.11](#411-layouts).

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

### 4.10 Last rendered position, and the `rendered` flag

When a widget is rendered, its absolute coordinates are stored in `lpos`
("last position", also exposed as `rendered_geometry`), a `RenderedGeometry`
object carrying `xi/xl/yi/yl` plus lazily-computed cached copies of the `a*`
and `i*` values and a `renders` counter. Because the parent is always rendered
before its children, a child can rely on the parent's `lpos` being current.
The same object is reused every frame — read it, don't retain it; for a
value-type snapshot use `absolute_geometry : Rectangle?`
([§4.2](#42-three-views-of-a-widgets-geometry)).

This is why the position getters take a `rendered` flag:

- `rendered == false` (the default for ordinary position queries) computes
  against the live parent widget.
- `rendered == true` resolves against the parent's `lpos` instead of
  recomputing it. If the parent's cached `a*` values are not yet filled in,
  they are computed once from the stored `xi/xl/yi/yl`, then reused. This is
  more accurate during rendering because it reflects effects like content
  shrinkage that a fresh recomputation might miss.

### 4.11 Layouts

A layout engine is a strategy object (under the `Crysterm::Layout` namespace,
in `src/layout/`) installed on any container widget — it is **not** itself a
widget (cf. Qt's `QLayout`). The container owns its rectangle, border and
padding; the layout only positions the children inside it:

```crystal
box = Widget::Box.new parent: window, width: 40, height: 10,
  layout: Layout::HBox.new(spacing: 1)
Widget::Box.new parent: box, width: 8   # fixed
Widget::Box.new parent: box             # flexes to fill the rest
```

The engines that ship today:

- `Layout::HBox` / `Layout::VBox` — Qt-style single-axis boxes; children with no
  explicit main-axis size share the leftover space equally, and are stretched to
  fill the cross axis.
- `Layout::Border` — the five-region dock (header/footer/sidebars/center) most
  application chrome wants. See the hint below.
- `Layout::Stack` — Qt's `QStackedLayout`: every child fills the container, only
  `#current` renders.
- `Layout::Grid` / `Layout::UniformGrid` — table-like rows and columns.
- `Layout::Form` — label/field pairs.
- `Layout::Masonry` / `Layout::Wrap` — inline flow of variably-sized children.
- `Layout::Manual` — the default when no engine is installed: children keep
  their own coordinates. What you want for free-floating overlays and for
  sprites whose position *is* application state.

Some engines take a **per-child hint**, read off `Widget#layout_hint`. The
common one is a `Border` region, which you give as a plain symbol:

```crystal
frame = Widget::Box.new parent: window, width: "100%", height: "100%",
  layout: Layout::Border.new
Widget::MenuBar.new parent: frame, height: 1, layout_hint: :top
Widget::StatusBar.new parent: frame, height: 1, layout_hint: :bottom
Widget::Box.new parent: frame, width: 20, layout_hint: :left
body = Widget::Box.new parent: frame, layout_hint: :center   # takes what's left
```

An edge child declares only the size it consumes (a `:top` child its `height`, a
`:left` child its `width`); the engine spans the other axis and hands the
remainder to `:center`. Nothing needs a hand-computed `"100%-1"` or a `top:`
counted off the bar above it.

**Hiding a child releases its slot.** A packing engine (`HBox`/`VBox`/`Border`)
arranges as though a hidden child weren't there, so `#hide` alone collapses a bar
and gives its space back — Qt's `QLayout` behavior:

```crystal
footer_hint.hide    # the rows below it move up; nothing else to do
```

Set `retain_size_when_hidden = true` to hide a widget *in place* instead, holding
its space open so its neighbours don't shift (Qt's
`QSizePolicy::retainSizeWhenHidden`). Slot-addressed engines — `Stack` pages and
`Grid` cells — always keep a hidden child's index, since their children are
identified by position.

**Filling a box the Qt way.** `Layout::Box` (HBox/VBox) carries Qt's
`QBoxLayout` surface: `add_widget w, stretch: 2, align: :end`,
`insert_widget`, `add_spacing(5)` (a fixed inert gap), `add_stretch(2)` (a
growing one), `set_stretch w, n` and `set_alignment w, :center`. Leftover
main-axis space goes to the flexing children in proportion to their `stretch`
factor (default 1); when nothing flexes, `justify` (`Start`/`Center`/`End`/
`SpaceBetween`/`SpaceAround`) distributes it; `align` (`Stretch`/`Start`/
`Center`/`End`) places children on the cross axis. `orientation` is writable
at runtime (Qt's `setDirection`).

#### Your specs stay yours: the layout-geometry channel

An engine never writes a child's `left`/`top`/`width`/`height` specs. Its
assignments travel through a separate per-widget *layout-geometry* channel
that resolution prefers while the child is managed. Consequences you can rely
on:

- `w.width` always reads what *you* set — `"50%"` stays `"50%"` at any point
  in any frame, and re-resolves against the live container every frame.
- **Reclaiming is exact**: set any non-nil spec (`child.width = 20` — even
  the very value the engine last assigned) and that axis is yours again from
  the next frame; a `nil` spec hands it back to the engine.
- A stable layout emits **no** `Move`/`Resize` events after its first frame
  (assignments are change-guarded).
- Removing the layout (`box.layout = nil`) or reparenting the child clears
  the channel — geometry reverts to the child's own specs, nothing sticks.

#### Size policy and hints

`Widget#size_policy` (Qt's `QSizePolicy`, deliberately smaller) overrides the
spec-derived behavior per axis. It is a pair of per-axis policies —
`SizePolicy.new(horizontal, vertical)`, or `set_size_policy h, v`; symbols
autocast:

- `Auto` (default) — derive from the spec: an explicit size acts as `Fixed`,
  a `nil` spec as `Expanding`. Exactly the behavior described above, so
  programs that never touch `size_policy` are unaffected.
- `Fixed` — the widget's own resolved size is authoritative; the engine never
  grows or shrinks that axis.
- `Preferred` — `size_hint` ([§4.8](#48-shrink-to-fit-widgets-and-size-hints))
  is the ideal: the engine assigns it, may shrink it when space runs short,
  but never grows it.
- `Expanding` — take a stretch-weighted share of the leftover space, even
  over an explicit size spec.

```crystal
row = Widget::Box.new parent: window, height: 1, layout: Layout::HBox.new
label = Widget::Box.new parent: row, content: "Name:"
label.size_policy = Widget::SizePolicy.new(:preferred, :auto) # width = its text
Widget::LineEdit.new parent: row                              # takes the rest
```

Today `Layout::Box` consumes the policy; the other engines arrange as if
every axis were `Auto`.

Note that a layout assigns a child's position and size **during a frame**. Before
the first render that arranges it, a layout-managed child has no resolved
geometry — so code that must *read* that geometry (or focus a text field, so its
caret lands in the right column) needs one synchronous `window.repaint` first.
See [§2.3](#23-what-exec-does).

The table widgets (`Widget::Table`, `Widget::ListTable`) instead mix in the
`TableLayout` *content* layout, which lays out cell text within the widget's own
content rather than arranging child widgets.

Adding a new arrangement strategy is small: subclass `Crysterm::Layout` (or
`Layout::Flow` for a row-wrapping engine) and implement `#arrange` — place
each child via `place_child`/`place_and_render`, which write through the
layout-geometry channel described above.

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
- **Thickness > 1.** A side thicker than one cell reserves that much space
  (reducing content area accordingly, like padding) and fills its whole reserved
  band: the run glyph repeats across the band and the corner block uses the
  corner glyph. Cells are classified by which band(s) they fall in — horizontal
  (top/bottom), vertical (left/right), or a corner where the two meet — so a
  `Bg` border can use distinct chars for each (`char_horizontal`,
  `char_vertical`, `char_corner`, all defaulting to `char`).
- **Border + scrollbar.** When a widget has a scrollbar, it normally renders in
  the rightmost content column. With a border present it moves one column
  inward. If the scrollbar's style has `ignore_border?` set, it instead renders
  *in* the border column, reusing that column.
- **Docking.** When the screen has `dock_borders` enabled, adjacent line borders
  are joined at the points where they meet — straight runs and the appropriate
  junction glyphs (`┬ ┴ ├ ┤ ┼`) are chosen automatically for a more elegant look.
  The screen's
  `dock_contrast` setting (`Skip` / `Blend` / `Ignore`) governs what happens
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
hold it and stores it in the widget's `label_widget` property; you can then
manipulate that box afterward. The label subscribes to events on its parent (e.g.
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
keep that in mind when mutating a style in place. (In-place mutation is fully
supported: damage tracking observes it, so `w.style.fg = ...` per frame is the
sanctioned animation idiom, no manual repaint call needed.)

Note that `style=` writes the *inline* override while the `style` reader
returns the *resolved* style, so they are not a strict property pair —
`inline_style`/`inline_style=` are the honest spellings of the override half.
In one situation the reader hands out a transient object instead of the
persistent style: a focused/selected widget with no theme and no colors of its
own renders through a throwaway reverse-video copy. That copy is frozen —
writing an attribute to it raises `Style::FrozenError` instead of silently
vanishing — and the persistent write paths are `restyle { }`, `state_style`,
or `inline_style=`:

```crystal
w.restyle &.bg = "red"   # mutate the persistent state style + repaint
```

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

The repaint verbs mirror Qt's pair and are the same on `Window` and `Widget`:

- **`update`** — schedule a coalesced repaint (Qt's `QWidget::update()`). The
  default; every tracked setter calls it for you. On a widget it is a no-op
  mid-frame (layout writes must not re-arm the frame they belong to).
- **`Widget#update!`** — the unconditional variant: still rings the doorbell
  mid-frame, for drivers that deliberately want *another* frame (animations,
  media decode).
- **`repaint`** — build a frame synchronously, on the calling fiber (Qt's
  `QWidget::repaint()`). On a widget, paints just that widget.
- **`Widget#paint`** — the overridable paint entry a subclass implements
  (Qt's `paintEvent()` analogue); called by the pipeline, not by users.

The old spellings — `Window#render`, `Widget#render`, `Widget#mark_dirty`,
`Widget#request_render` — have been removed. A subclass that overrode
`render(with_children = true)` must rename the override to `paint` (the
pipeline dispatches through `paint`).

### 8.1 The pipeline

`Window#update` (usually invoked indirectly) schedules a frame. When the frame
runs (`Window#repaint` builds one synchronously, on the calling fiber):

1. Emits `Event::PreRender`.
2. Clears the in-memory cell buffer (`@lines`) back to the default cell. Widgets
   are repainted from scratch every frame, so the buffer always starts clean.
   This also makes alpha/transparency blending correct (each frame blends over
   the base, not over the previous frame's already-blended result) and removes
   the need to manually clear spots a widget has vacated.
3. Walks the window's direct children in order and calls `paint` on each, which
   recursively renders their children. Each widget paints itself into `@lines`.
4. Optionally docks borders (when `dock_borders` is on).
5. Calls **`draw`**, which compares the new buffer to what is on the terminal and
   emits only the differences.
6. Emits `Event::Rendered`.

Because children are painted in order and later widgets overwrite earlier cells,
this is effectively a [painter's algorithm](https://en.wikipedia.org/wiki/Painter%27s_algorithm).

### 8.2 Damage tracking

`draw` is the differential part. The window keeps two grids: `@lines` (the new,
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
requests are spaced out to honor `interval`. As a result you can call `update`
from anywhere at any time — all the changes accumulated since the last frame are
painted together in one pass, and isolated updates are not delayed.

### 8.5 Timers and the frame clock

The two everyday timers live on `Window` and drive both animation and delayed
work; each returns the `FrameClock` behind it, so it can be cancelled:

```crystal
# Recurring: invoke the block, render, sleep, repeat — until stopped.
clock = window.every(0.1.seconds) { progress.value += 1 }
clock.stop

# The block is also handed the timer, so a repeater can stop itself —
# and `times:` runs a fixed count without any bookkeeping.
window.every(0.1.seconds) { |t| t.stop if progress.value >= 100 }
window.every(0.1.seconds, times: 10) { progress.value += 10 }

# One-shot (`QTimer::singleShot` analog): invoke the block once after the span.
clock = window.after(2.seconds) { status.content = "Saved." }
clock.stop # cancels it if it hasn't fired yet
```

Both render after each block call, so the body only needs to mutate state — no
explicit `update` inside. `every` is phase-locked: the period stays at the given
interval regardless of how long the block takes.

The blocks run on their own fiber, off the render fiber, interleaved with it by
the scheduler — the single-threaded model of
[§3.3](#33-the-single-threaded-render-model) applies, so no locking is needed.
Because the render they trigger goes through the coalescing doorbell of
[§8.4](#84-frame-coalescing-and-the-interval), many fast timers still produce
at most one frame per render interval.

`every`/`after` delegate to `Timer.every`/`Timer.single_shot` — the same
timers minus the render, for work not tied to a window. `Timer.new` itself,
like `QTimer`, never starts on its own: build a shared clock with
`Timer.new(0.1.seconds).start` and pass it around (e.g. as a widget's
`animate:` clock).

`FrameClock` itself (see its class docs) is the underlying primitive, built
by shape: `FrameClock.ticker` (repeating) or `FrameClock.tween` (duration-
bound and eased, with a completion callback), used by animations,
transitions, and effects. `every`/`after` are the
convenience entry points; construct a `FrameClock` directly when you need
easing or a bounded duration.

---

## 9. The cursor

The cursor belongs to the `Window` and is available as `Window#cursor`. It is a
small object (`Crysterm::Cursor`, extending `Tput::Namespace::Cursor`) holding
the cursor's shape, blink state, and a `style` (a `Style` used for the cursor's
color and glyph; its default `char` is `▮`).

`Window#cursor` is the surface *default*. A `Widget` may own a cursor too, and
the one actually in effect is `Window#active_cursor` — the focused widget's own
cursor, else the window default. Everything that draws or applies the cursor
goes through it.

The hardware primitives (the capability probes and the raw shape/color/show/hide
`tput` calls) live on the device, `Screen`; the `Window` delegates to them and
decides hardware-vs-artificial (see below).

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

The main operations, all on `Window`:

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
`_artificial_cursor_attr` and drawn during `Window#draw` at the terminal's
current cursor position: a `Line` shape renders as a `│` glyph, `Underline` adds
the underline attribute, `Block` inverts the cell, and `None` falls back to the
cursor's own `style` (including a custom `char` and colors).

> A per-widget cursor is already supported (`Widget#cursor`, resolved through
> `Window#active_cursor`); `Window#cursor` remains the fallback for widgets that
> define none.

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

External sources are applied automatically: at `require "crysterm"` time the
library runs `Crysterm.configure!` once, so the config file, `CRYSTERM_*` env
vars, and command-line flags are honored by every app with no per-app call.
(This happens at load time because many options are read as `Window` property
defaults at the start of `initialize` — too early for a later call to affect.)
To disable it — e.g. for a fully hermetic program — set the
`CRYSTERM_NO_AUTO_CONFIGURE` environment variable to a non-empty value; then
every option keeps its registered default unless your code calls `configure!`
itself.

### Surfaces

For an option with key `window.resize_interval`:

| Surface | Form |
|---|---|
| Config key | `window.resize_interval` (YAML: `window: { resize_interval: 0.5 }`) |
| Environment variable | `CRYSTERM_WINDOW_RESIZE_INTERVAL` |
| Command-line option | `--window-resize-interval=0.5` |
| Runtime | `Crysterm::Config.window_resize_interval` (typed accessor) |

Reading and writing at runtime use the typed accessor — the option key with
dots turned into underscores — so there's no string key or type argument, and
it's a cached read (no registry lookup):

```crystal
Crysterm::Config.window_resize_interval        # => Time::Span
Crysterm::Config.window_resize_interval = 0.5.seconds
```

(`Crysterm::Config.get("window.resize_interval", Time::Span)` and `.set` also
exist for fully dynamic, string-keyed access — that's what the loaders use.)

### Re-applying and overriding

`configure!` may also be called explicitly — to load an additional file, or to
re-apply the sources after the automatic load-time pass:

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
$ CRYSTERM_WINDOW_RESIZE_INTERVAL=0.5 myapp --render-optimization=smart_csr,bce --dump-config=pretty
OPTION                  VALUE           SOURCE
----------------------  --------------  ------
render.optimization     SmartCSR | BCE  command line (--render-optimization)
window.resize_interval  0.5             env CRYSTERM_WINDOW_RESIZE_INTERVAL="0.5"
...
```

Any Crysterm app accepts these out of the box: `crystal tests/hellos/hello.cr -- --dump-config=pretty`.

## 12. Differences from Blessed

**Positioning and sizing**

- In Blessed the user-set values live in `widget.position.*` and `left`/`top`/…
  read from there. In Crysterm the Spec getters `left`/`top`/`right`/`bottom`
  (and `width_spec`/`height_spec` — the bare `width`/`height` read as resolved
  cells, the Qt/CSS convention) *are* the raw user values, the absolute
  resolved values are `aleft`/`atop`/…,
  and the relative resolved values are `rleft`/`rtop`/… (in the spec space, so
  `w.left = w.rleft` is a no-op). The accessor table in
  [§4.2](#42-three-views-of-a-widgets-geometry) is the streamlined Crysterm
  interface.
- Blessed's "shrink" option is called **`shrink_to_fit`** in Crysterm,
  reflecting that it sizes to content (and can grow as well as shrink).

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
  the same with a generic `Widget::Box` (stored in `label_widget`) but, in
  principle, allows any widget to serve as a label.

**Styling**

- Blessed's styling is spread across several places; Crysterm consolidates
  everything style-related under `Widget#style`, with per-state styles in a
  `Styles` container and per-sub-element styles inside each `Style`. The shared
  default is `Styles.default` (note: on the `Styles` container, not a
  `Style.default`).
