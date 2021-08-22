[![Linux CI](https://github.com/crystallabs/crysterm/workflows/Linux%20CI/badge.svg)](https://github.com/crystallabs/crysterm/actions?query=workflow%3A%22Linux+CI%22+event%3Apush+branch%3Amaster)
[![Version](https://img.shields.io/github/tag/crystallabs/crysterm.svg?maxAge=360)](https://github.com/crystallabs/crysterm/releases/latest)
[![License](https://img.shields.io/github/license/crystallabs/crysterm.svg)](https://github.com/crystallabs/crysterm/blob/master/LICENSE)

# Crysterm

Crysterm is a console/terminal toolkit for Crystal.

See the presentation from Crystal 1.0 Conference: https://www.youtube.com/watch?v=UQCEIBzQOec

At the moment Crysterm follows closely the implementation and behavior of libraries that inspired it,
[Blessed](https://github.com/chjj/blessed) and [Blessed-contrib](https://github.com/yaronn/blessed-contrib)
for Node.js. However, being implemented in Crystal (an OO language), it tries to use the language's
best practices, avoid bugs and problems found in Blessed, and also (especially in the future) incorporate
more aspects of [Qt](https://doc.qt.io/).

## Trying out the examples

```
git clone https://github.com/crystallabs/crysterm
cd crysterm
shards --ignore-crystal-version

export TERM=xterm-256color

crystal examples/hello.cr
crystal examples/hello2.cr
crystal examples/tech-demo.cr

# And other examples from directories examples/, small-tests/, and test/.
```

## Using it as a module in your project

Add the dependency to `shard.yml`:

```yaml
dependencies:
  crysterm:
    github: crystallabs/crysterm
    branch: master
```

Then add some code to your project, e.g.:

```
require "crysterm"

alias C = Crysterm

display = C::Display.new # Becomes the first/global display
screen = C::Screen.new # Assumes argument `display: Display.global`

hello = C::Widget::Box.new \
  name: "helloworld box", # Symbolic name
  top: "center",          # Can also be 10, "50%", or "50%+-10"
  left: "center",         # Can also be 10, "50%", or "50%+-10"
  width: 20,              # Can also be 10, "50%", or "50%+-10"
  height: 5,              # Can also be 10, "50%", or "50%+-10"
  content: "{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
  parse_tags: true,       # Parse {} tags within content (default already is true)
  style: C::Style.new(fg: "yellow", bg: "blue"),
  border: true            # 'true' for default type/look

screen.append hello

# When q is pressed, exit.
screen.on(C::Event::KeyPress) do |e|
  if e.char == 'q'
    display.destroy
    exit
  end
end

display.exec
```

## Screenshots

Animated demo

![Crysterm Demo Video](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/2020-01-29-1.gif)

Layout engine (showing inline/masonry layout)

![Crysterm Masonry Layout](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/layout.png)

Transparency, color blending, and shadow

![Crysterm Color Blending](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/transparency.png)

## Development

### Introduction

As mentioned, Crysterm is inspired by Blessed, Blessed-contrib, and Qt.

Blessed is a large, self-contained framework. Apart from implementing Blessed's core functionality, its authors have also
implemented all the necessary/prerequisite components, including an event model (a modified copy of an early Node.js
EventEmitter), complete termcap/terminfo system (parsing, compilation, output, and input from terminal devices; in a word an
alternative to ncurses), all types of mouse support, Unicode handling, color manipulation routines, etc.
However, these implementations have been mixed with the rest of Blessed's source code, reducing the potential for their
reuse.

In Crysterm, the equivalents of those components have been created as individual shards, making them available
to the whole Crystal ecosystem. The event model has been implemented in
[event_handler](https://github.com/crystallabs/event_handler), color routines in
[term_colors](https://github.com/crystallabs/term_colors), terminal output in
[tput.cr](https://github.com/crystallabs/tput.cr), GPM mouse in
[gpm.cr](https://github.com/crystallabs/gpm.cr), and terminfo library in
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
1. Porting everything of value remaining in blessed-clean (most notably: reading terminfo command responses from terminal, mouse support, full unicode (graphemes), and a number of widgets)
1. Porting over widgets & ideas from blessed-contrib
1. Developing more line-oriented features. Currently Crysterm is suited for full-screen app development. It would be great if line-based features were added, and if then various small line-based utilities that exist as shards/apps for Crystal would be ported to become Crysterm's line- or screen-based widgets
1. Adding features and principles from Qt

Those are generalal guidelines. For smaller, more specific development/contribution tasks, grep sources for "TODO", "NOTE", and "XXX",  see file `TODO`, and see general Crystal wishlist in file `CRYSTAL-WISHLIST`.

### Event model

Event model is at the very core of Crysterm, implemented via [event_handler](https://github.com/crystallabs/event_handler).

Please refer to [event_handler](https://github.com/crystallabs/event_handler)'s documentation for all usage instructions.

The events used by Crysterm and its widgets are defined in `src/events.cr`.

### Class Hierarchy

1. Top-level class is `Display`. It represents a physical device / terminal used for `@input` and `@output` (Blessed calls this `Program`)
1. Each display can have one or more `Screen`s (Blessed also calls this `Screen`). Screens are always full-screen and represent the whole surface of a Display
1. Each screen can have one or more `Widget`s, arranged appropriately to implement final apps

The default `Display` and `Screen` do not need to be created explicitly if you don't need to change any of their options. They will be created automatically if missing when the first `Widget` is created.

Widgets can be added and positioned on the screen directly, but some widgets are particularly suitable for containing or arranging other/child widgets.
Most notably this is the `Layout` widget which can auto-size and auto-position contained widgets in the form of a grid or inline (masonry-like) layout (`LayoutType::{Grid,Inline}`).

There are currently no widgets that would represent GUI windows like `QWindow` or `QMainWindow` in Qt
(having title bar, menu bar, status bar, etc.), but implementing them is planned. (`Window`s too will inherit from `Widget`.)

All mentioned classes `include` [event_handler](https://github.com/crystallabs/event_handler) for event-based
behavior.

### Positioning and Layouts

![Crysterm Widget](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/widget.png)

Widget positions and sizes work like in Blessed. They can be specified as numbers (e.g. 10), percentages (e.g. "10%"), both (e.g. "10%+2"), or specific keywords ("center", which has an effect of `50% - self.width_or_height//2`, or "resizable" which adjusts in runtime).

That model is simple and works quite OK, although it is not as developed as the model in Qt. For example, there is no way to shrink or grow widgets disproportionally when window is resized, and
there is no way to define maximum or minimum size. (Well, minimum size calculation does exist for resizable widgets, but only for trying to find the minimum size based on actual
contents, rather than programmer's wishes. (What we call "resizable" is suboptimally called "shrink" in Blessed because it can also grow.))

Speaking of layouts, the one layout engine currently existing, `Widget::Layout`, is equivalent to Blessed's. It can arrange widgets in a grid-like or masonry-like style.
There are no equivalents of Qt's `QBoxLayout`.

The positioning and layout code is very manageable; adding new Qt-like or other features is not a big task.
(Whether various layouts would then still inherit from `Widget` or not (like they don't in Qt) is open for consideration.)

Finally, worth noting, there are currently some differences in the exact types or combinations of mentioned values supported for `top`, `left`, `width`, `height`, and `align`. It would be
good if all these could be adjusted to accept the same flexible/unified specification, and if the list of supported specifications would even grow over time.
(For example, one could want to pass a block or proc, in which case it'd be called to get the value.)

### Rendering and Drawing

Screens contain widgets. To make screens appear on display with all the expected contents and current state,
one calls `Screen#render`. This function calls `Widget#render` on each of direct children elements, which
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

### Text Attributes and Colors

Crysterm implements its own concept of "tags" in strings,
such as `{light-blue-fg}Text in Light Blue{/light-blue-fg}`. Tags can be embedded in strings directly, applied
from a Hash with `generate_tags`, or removed from a string with `strip_tags` or `clean_tags`.
Any existing strings where "{}" should not be interpreted can be protected with `escape_tags`.

The supported tags are: `{center}`, `{left}`, and `{right}` for alignment,
`{normal | default}`, `{bold}`, `{underline | underlined | ul}`, `{blink}`, `{inverse}`, and `{invisible}` for text attributes,
`{COLOR-fg}` and `{COLOR-bg}` for colors,
and `{/}` for closing all open tags.

Supported COLOR names are:
`default`,
`black`,
`blue`,
`bright-black`,
`bright-blue`,
`bright-cyan`,
`bright-gray`,
`bright-green`,
`bright-grey`,
`bright-magenta`,
`bright-red`,
`bright-white`,
`bright-yellow`,
`cyan`,
`gray`,
`green`,
`grey`,
`light-black`,
`light-blue`,
`light-cyan`,
`light-gray`,
`light-green`,
`light-grey`,
`light-magenta`,
`light-red`,
`light-white`,
`light-yellow`,
`magenta`,
`red`,
`white`,
`yellow`.

In addition to the above color names, one can also specify colors by color index (syntax: `{ID-...}`), or by RGB hex
notation using the 16M color palette (syntax `{#RRGGBB-...}`. 16M RGB is the recommented way to define colors, and
Crysterm will automatically reduce them to 256, 16, 8, or 2 colors if/when needed, depending on terminal capabilities.

One could also define foreground and background colors and attributes by manually
embedding the appropriate escape sequences into strings or using Crystal's `Colorize` module.
Crysterm is interoperable with those approaches.

### Styling

Every `Widget` has an attribute `style`, defining the colors and attributes to use during rendering.
If no style is explicitly defined, the default style is instantiated. Apart from styling the widget
itself, each `Style` may have overriding style definitions for widget's possible subelements
(border, scrollbar, track, bar, item, header, cell, label) and states (focus, blur, hover, selected).

If any of these subelements have more specific settings which define substantial behavior and not
just visual aspects, they are defined as properties directly on the widget (e.g. `Widget#border`,
`Widget#scrollbar`, etc.). These properties also serve as toggles that turn on or off respective
elements.

The final goal (still to be implemented) is to be able to define one or a couple `Style` instances
which would apply to, and style, all widgets. Additionally, these definitions would be
serializable to YAML, enabling convenient theming.

### Performance

By default, for development, frames-per-second value is displayed at the bottom of every Screen. When displaying FPS is enabled, Crysterm measures time needed to complete rendering and drawing cycles, and displays them as "R/D/FPS" (estimated renderings per second, drawings per second, and total/combined frames per second). Such as:

```
R/D/FPS: 761/191/153 (782/248/187)
```

The first 3 values display the performance of the current frame, and the values in parentheses display the averages over 30 frames.

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

List of notable differences (hopefully improvements) compared to Blessed:

- `Program` has been renamed to `Display` (representing a physical display managed by Crysterm)
- `Element` and `Node` have been consolidated into `Widget`
- `Screen` no longer inherits from `Widget`
- As such, `Screen` is not a top-level `parent` of any `Widget`; use `[@]screen` to get `Screen` or `parent_or_screen` for parent or screen
- `auto_padding` and `tabc` are properties on `Widget` instead of `Screen`
- `tab_size` is a property on `Style` instead of `Screen`
- Event names have been changed from strings to classes, e.g. event `"scroll"` is `::Crysterm::Event::Scroll`
- `tags` alias for `parse_tags` option has been removed; use `parse_tags: true/false`. Default is true
- All terminal-level stuff is in shard `Tput`, not `Crysterm`
- `style` property has been consolidated; all style-related stuff is under widget's `@style : Style`
- Widget property `shadow` is a bool, and default amount of transparency is `style.shadow_transparency = 0.5`
- Style property `transparent` has been renamed to `transparency` and also accepts Float64, in addition to `true` which defaults to 0.5
- In `Widget::ProgressBar`, the display of value is done using foreground color. This is different than Blessed and arguably more correct (Blessed uses background color)
- In Crysterm, default border type is "line" (`BorderType::Line`). In Blessed it is "bg"
- In Blessed, there is variable `ignore_dock_contrast`, which if set to true will cause borders to always be docked, or if set to false it will not dock borders of different colors. In Crysterm, this variable is defined as `@dock_contrast: DockContrast`, and `DockContrast` is an enum that can be `Ignore`, `DontDock`, or `Blend`. The first two behave like Blessed's true and false respectively, and `Blend` is a new option that blends colors and docks.
- In Crysterm, `attaching`/`detaching` Widgets is only applicable on Screens and it means setting/removing property `#screen` on the desired widget and its children (it does not have anything to do with widget parent hierarchy). Although in most cases these functions are not called directly but are invoked automatically when calling functions to set widgets' parents.
- Widget property `valign` has been removed because property `align` is an enum (`Tput::AlignFlag`) and encodes both horizontal and vertical alignment choices in the same value
- Widget methods `#<<` and `#>>` can be used for adding/removing children elements depending on argument type. E.g., `<< Widget` adds a Widget as a child of parent widget, and `<< Action` adds an Action into the parent widget's list of actions.
- It is hard to remember whether screen size is kept in property `columns` or `cols`. So in Crysterm the `Screen`s dimensions are in `width` and `height`, and this is uniform with all `Widget`s which also have their size in `width` and `height`.
- `shrinkBox` is `Rectangle` in Crysterm, and `_get_shrink` is `_get_minimal_rectangle`
- User-specified Widget options left, top, right, bottom, width, height, and resizable exist directly on `Widget` in Crysterm, rather than on `Widget.position`. Also, to get actual numbers/values out, one now needs to explicitly use e.g. `aleft` (absolute left), `rleft` (relative left) or `ileft` (inner/content left). This removes all ambiguity and lack of straightforwardness in which value is being accessed
- Widgets can have shadow on any of the 4 sides, instead of always being drawn on the right and bottom
- `widget.noFill` is `!style.fill?` in Crysterm

List of current bugs / quirks in Crysterm, in no particular order:

- It is likely that Crysterm's API interface and general usability could be improved in many places. Fortunately those are easy improvements and/or suggestions that can be made by early users and adopters
- Screen's top-level widgets need to be added to `Screen` with `screen.append widget` explicitly (option `screen: screen` to `Widget.new` doesn't do everything it should at the moment)
- Items need to be added to `Widget::List` explicitly, after list creation (option `items: [...]` to `List.new` isn't available at the moment)
- `Widget::Layout` needs explicit width and height (e.g. "100%"). It seems this isn't needed in Blessed
- `Widget::TextArea` lacks many features (deficiency inherited from Blessed)
- Scrollbar on a widget can be enabled with `scrollbar: true`. Styling for the scrollbar column is taken from `@style.track` and for the scrollbar character from `@style.scrollbar`. This is inherited from Blessed and unintuitive. `style.scrollbar` should be the column, and `style.track` (or other name) should be the scroll position indicator.
- Some parts of code are marked with "D O:" or "E O:". These mean "Disabled Originally" and "Enabled Originally", indicating whether respective parts of code were disabled or enabled "originally" (in Blessed sources). Those marked with "D O:" do not need any work unless they were part of unfinished improvements in Blessed, in which case they probably should be developed/enhanced in Crysterm.
- In some places functions like '#setX' have been renamed to '#x=' while in others they weren't.
- There is no `Image` widget which can display an image in ANSI or an overlay. Use one or the other (`Widget::Image::Ansi` or `Widget::Image::Overlay`) explicitly. (`Image::Ansi` does not exist yet.)

If you notice any problems or have any suggestions, please submit an issue.

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
