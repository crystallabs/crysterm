[![Linux CI](https://github.com/crystallabs/crysterm/workflows/Linux%20CI/badge.svg)](https://github.com/crystallabs/crysterm/actions?query=workflow%3A%22Linux+CI%22+event%3Apush+branch%3Amaster)
[![Version](https://img.shields.io/github/tag/crystallabs/crysterm.svg?maxAge=360)](https://github.com/crystallabs/crysterm/releases/latest)
[![License](https://img.shields.io/github/license/crystallabs/crysterm.svg)](https://github.com/crystallabs/crysterm/blob/master/LICENSE)

# Crysterm

Crysterm is a console/terminal toolkit for Crystal.

At the moment it follows closely the implementation and behavior of the libraries that inspired it,
[Blessed](https://github.com/chjj/blessed) and [Blessed-contrib](https://github.com/yaronn/blessed-contrib)
for Node.js. However, being implemented in Crystal (an OO language), it tries to use the language's
best practices, avoid bugs and problems found in Blessed, and also (especially in the future) incorporate
some aspects of [Qt](https://doc.qt.io/).

## Trying it out

```
git clone https://github.com/crystallabs/crysterm
cd crysterm
shards --ignore-crystal-version

export TERM=xterm-256color

crystal examples/hello.cr
crystal examples/hello2.cr
crystal examples/tech-demo.cr
```

(If you get an Exception trying to run the "tech-demo" example, maximize your terminal window and try
again.)

## Screenshots

Animated demo

![Crysterm Demo Video](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/2020-01-29-1.gif)

Layout engine (showing inline/masonry layout)

![Crysterm Masonry Layout](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/layout.png)

Transparency, color blending, shadow

![Crysterm Color Blending](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/transparency.png)

## Development

### Introduction

As mentioned, Crysterm is inspired by Blessed, Blessed-contrib, and Qt.

Blessed is a large, self-contained framework. Apart from implementing Blessed, its authors have also implemented
all the necessary/prerequisite components, including an event model (a modified copy of an early Node.js EventEmitter),
complete termcap/terminfo system (parsing, compilation, output, and input from terminal devices; in a word an
alternative to ncurses), all types of mouse support, Unicode handling, color manipulation routines, etc.
However, these implementations have been mixed with the rest of source code, reducing the potential for their
reuse.

In Crysterm, the equivalents of those components have been created as individual shards, making them available
to the whole Crystal ecosystem. The event model has been implemented in
[EventHandler](https://github.com/crystallabs/event_handler), color routines in
[term_colors](https://github.com/crystallabs/term_colors), terminal output in
[tput.cr](https://github.com/crystallabs/tput.cr), and terminfo library in
[unibilium.cr](https://github.com/crystallabs/unibilium.cr).

Unibilium.cr represents Crystal's bindings for
a C terminfo library called [unibilium](https://github.com/neovim/unibilium/), now maintained by Neovim.
The package exists for a good number of operating systems and distributions, and one only needs the binary
library installed, not headers.
There is also a mostly working Crystal-native terminfo library available in
[terminfo.cr](https://github.com/crystallabs/terminfo.cr) but, due to other priorities, trying to use that instead
of unibilium is not planned. Both unibilium and native terminfo implementation for Crystal were initially
implemented by Benoit de Chezelles (@bew).)

Crysterm closely follows Blessed, and copies of Blessed's comments have been included in Crysterm's sources for
easier correlation and search between code, files, and features. A copy of Blessed's repository also exists in
[docelic/blessed-clean](https://github.com/docelic/blessed-clean). It is a temporary repository in which
files are deleted after their contents are reviewed and discarded or implemented in Crysterm.

High-level development plan for Crysterm looks as follows:

1. Improving Crysterm itself (fixing bugs, replacing strings with better data types (enums, classes, etc.), and doing new development).
1. Porting everything of value remaining in blessed-clean (most notably: reading terminfo command responses from terminal, mouse support, artificial cursor, full unicode (graphemes), and a number of widgets)
1. (Because Blessed is no longer in active development) Reviewing the updates Blessed has received in forked repositories neo-blessed and blessed-ng, and using them in Crysterm where applicable
1. Porting over widgets & ideas from blessed-contrib
1. Developing more line-oriented features. Currently Crysterm is suited for full-screen app development. It would be great if line-based features were added, and if then various small line-based utilities that exist as shards/apps for Crystal would be ported to become Crysterm's line- or screen-based widgets
1. Adding features and principles from Qt

Those are generalal guidelines. For smaller, more specific development/contribution tasks, grep sources for "TODO", "NOTE", and "XXX",  see file `TODO`, and see general Crystal wishlist in file `CRYSTAL-WISHLIST`.

### Event model

Event model is at the very core of Crysterm, implemented via [EventHandler](https://github.com/crystallabs/event_handler).

The events used by Crysterm and its widgets are defined in `src/events.cr`.

### Class Hierarchy

1. Top-level class is `Display`. It represents a physical device / terminal used for `@input` and `@output` (Blessed calls this `Program`)
1. Each display can have one or more `Screen`s (Blessed also calls this `Screen`). Screens are always full-screen and represent the whole surface of a Display
1. Each screen can have one or more `Widget`s, arranged appropriately to implement final apps

Widgets can be added and positioned on the screen directly, but some widgets are particularly suitable for containing or arranging other/child widgets.
Most notably this is the `Layout` widget which can auto-size and auto-position contained widgets in the form of a grid or inline (masonry-like) layout (`LayoutType::{Grid,Inline}`).

There are currently no widgets that would represent GUI windows like `QWindow` or `QMainWindow` in Qt
(having title bar, menu bar, status bar, etc.), but implementing them is planned. (`Window`s too will inherit from `Widget`.)

All mentioned classes `include` [EventHandler](https://github.com/crystallabs/event_handler) for event-based
behavior.

### Positioning and Layouts

![Crysterm Widget](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/widget.png)

Widget positions and sizes work like in Blessed. They can be specified as numbers (e.g. 10), percentages (e.g. "10%"), both (e.g. "10%+2"), or specific keywords ("center", which has an effect of `50% - self.width_or_height//2`, or "resizable" which adjusts in runtime).

That model is simple and works quite OK, although it is not as developed as the model in Qt. For example, there is no way to shrink or grow widgets disproportionally when window is resized, and
there is no way to define maximum or minimum size. (Well, minimum size calculation does exist for resizable widgets, but only for trying to find the minimum size based on actual
contents, rather than programmer's wishes. (What we call "resizable" is called "shrink" in Blessed, even though it can also grow.))

Speaking of layouts, the one layout engine currently existing, `Widget::Layout`, is equivalent to Blessed's. It can arrange widgets in a grid-like or masonry-like style.
There are no equivalents of Qt's `QBoxLayout`.

The positioning and layout code is very manageable; adding new Qt-like or other features is not a big task.
(Whether various layouts would then still inherit from `Widget` or not (like they don't in Qt) is open for consideration.)

Finally, worth noting, there are currently some differences in the exact types or combinations of mentioned values supported for `top`, `left`, `width`, `height`, `align`, and `valign`. It would be
good if all these could be adjusted to accept the same flexible/unified specification, and if the list of supported specifications would even grow over time.
(For example, one could want to pass a block or proc, in which case it'd be called to get the value.)

### Rendering and Drawing

Screens contain widgets. To make screens appear on display with all the expected contents and current state,
one calls `Screen#render`. This function calls `Widget#render` on each of immediate child elements, which
results in the final/rendered state reflected in internal memory.

At the end of rendering, `Screen#draw` is automatically called which makes any changes in internal state appear on the
display. For efficiency, painter's algorithm is used, only changes ("damage") are rendered, and renderer
can optionally make use of CSR (change-scroll-region) and/or BCE (back-color-erase) optimizations
(see `OptimizationFlag`).

Calling `render` whereever appropriate is not a concern because there is code making sure that render
runs at most once per unit of time (currently 1/29th of a second) and all accumulated changes are
rendered in one pass.

When state has been set up for the first time and the program is to start running the display, one
generally calls `Display#exec`. This renders the specified (or default) screen and starts running the
program.

### Text Attributes

Crysterm implements its own concept of "tags" in strings,
such as "{lightblue-fg} text in light blue {/lightblue-fg}". Tags can be embedded in strings directly, applied
from a Hash with `generate_tags`, or removed from a string with `strip_tags` or `clean_tags`.
Any existing strings where "{}" should not be interpreted can be protected with `escape_tags`.

One could also define foreground and background colors and attributes by manually
embedding the appropriate escape sequences into strings or using Crystal's `Colorize` module.
Crysterm is interoperable with those approaches.

### Styling

Every `Widget` has an attribute `style`, defining the colors and attributes to use during rendering.
If no style is explicitly defined, the default style is instantiated. Apart from styling the widget
itself, each `Style` may have overriding style definitions for widget's possible subelements
(border, scrollbar, shadow, track, bar, item, header, cell, label) and states (focus, blur, hover, selected).

If any of these subelements have more specific settings which define substantial behavior and not
just visual aspects, they are defined as properties directly on the widget (e.g. `Widget#border`,
`Widget#scrollbar`, etc.). These properties also serve as toggles that turn on or off respective
elements.

The final goal (still to be implemented) is to be able to define one or a couple `Style` instances
which would apply to, and style, all widgets. Additionally, these definitions would be
serializable to YAML, enabling convenient theming.

### Performance

By default, for development, frames-per-second value is displayed at the bottom of every Screen. When displaying FPS is enabled, Crysterm measures time needed to complete rendering and drawing cycles, and displays them as "R/D/FPS" (estimated renderings per second, drawings per second, and total/combined frames per second).

Because the rendering+drawing cycle happens up to 29 times per second, the FPS value should stay above 30 of frame skipping could occur.

### Testing

Run `crystal spec` as usual.

More specs need to be added.

One option for testing, currently not used, would be to support a way where all output (terminal
sequences etc.) is written to an IO which is a file. Then simply the contents of that file are
compared with a known-good snapshot.

This would allow testing complete programs and a bunch of functionality at once, efficiently.

### Documentation

Run `crystal docs` as usual.

### Notable Differences

List of notable differences compared to Blessed:

- `Program` has been renamed to `Display` (representing a physical display managed by Crysterm)
- `Element` and `Node` have been renamed and consolidated into `Widget`
- `Screen` no longer inherits from `Widget`
- As such, `Screen` is not a top-level `parent` of any `Widget`; use `[@]screen` to get `Screen` or `parent_or_screen` for any
- `auto_padding`, `tab_size`, and `tabc` are properties on `Widget` instead of `Screen`
- Event names have been changed from strings to classes, e.g. event `"scroll"` is `::Crysterm::Event::Scroll`
- `tags` alias for `parse_tags` option has been removed; use `parse_tags: true/false`
- All terminal-level stuff is in shard `Tput`, not `Crysterm`
- `style` property has been consolidated; all style-related stuff is under widget's `@style : Style`
- Widget property `shadow` also accepts Float64, in addition to `true` which defaults to drawing shadow with alpha=0.5
- Style property `transparent` has been renamed to `transparency` and also accepts Float64, in addition to `true` which defaults to 0.5

List of current bugs/quirks in Crysterm:

- Top-level widget needs to be added to `Screen` with `screen.append widget` explicitly (option `screen: screen` to `Widget.new` doesn't do everything it should at the moment)
- `Widget::Layout` needs explicit width and height (e.g. "100%")

## Thanks

* All the fine folks on Libera.Chat IRC channel #crystal-lang and on Crystal's Gitter channel https://gitter.im/crystal-lang/crystal

## Other projects

List of interesting or similar projects in no particular order:

Terminal-related:

- https://github.com/Papierkorb/fancyline - Readline-esque library with fancy features
- https://github.com/r00ster91/lime - Library for drawing graphics on the console screen
- https://github.com/andrewsuzuki/termbox-crystal - Bindings, wrapper, and utilities for termbox

Colors-related:

- https://crystal-lang.org/api/master/Colorize.html - Crystal's built-in module Colorize
- https://github.com/veelenga/rainbow-spec - Rainbow spec formatter for Crystal
- https://github.com/watzon/cor - Make working with colors in Crystal fun!
- https://github.com/icyleaf/terminal - Terminal output styling
- https://github.com/ndudnicz/selenite - Color representation conversion methods (rgb, hsv, hsl, ...) for Crystal
- https://github.com/jaydorsey/colorls-cr - Crystal toy app for colorizing LS output

Event-related:

- https://github.com/crystallabs/event_handler - Event model used by Crysterm
- https://github.com/Papierkorb/cute - Event-centric pub/sub model for objects inspired by the Qt framework
- https://github.com/hugoabonizio/event_emitter.cr - Idiomatic asynchronous event-driven architecture

Misc:

- https://github.com/Papierkorb/toka - Type-safe, object-oriented option parser
- https://github.com/eliobr/termspinner - Simple terminal spinner
- https://github.com/epoch/tallboy - Draw ascii character tables in the terminal
- https://github.com/teuffel/ascii_chart - Lightweight console ASCII line charts
