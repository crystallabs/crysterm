[![Linux CI](https://github.com/crystallabs/crysterm/workflows/Linux%20CI/badge.svg)](https://github.com/crystallabs/crysterm/actions?query=workflow%3A%22Linux+CI%22+event%3Apush+branch%3Amaster)
[![Version](https://img.shields.io/github/tag/crystallabs/crysterm.svg?maxAge=360)](https://github.com/crystallabs/crysterm/releases/latest)
[![License](https://img.shields.io/github/license/crystallabs/crysterm.svg)](https://github.com/crystallabs/crysterm/blob/master/LICENSE)

# Crysterm

Crysterm is a console/terminal toolkit for Crystal.

At the moment Crysterm follows closely the implementation and behavior of libraries that inspired it,
[Blessed](https://github.com/chjj/blessed) and [Blessed-contrib](https://github.com/yaronn/blessed-contrib)
for Node.js. However, being implemented in Crystal (an OO language), it tries to use the language's
best practices, avoid bugs and problems found in Blessed, and also (especially in the future) incorporate
more aspects of [Qt](https://doc.qt.io/).

## Trying out the examples

```
git clone https://github.com/crystallabs/crysterm
cd crysterm
shards

crystal examples/hello.cr
crystal examples/hello2.cr
crystal examples/tech-demo.cr

# And other examples from directories examples/, small-tests/, test/ and test-auto/.
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

```cr
require "crysterm"

alias C = Crysterm

screen = C::Screen.new

# Optionally, you can include widgets in the current namespace:
# include Crysterm::Widgets

hello = C::Widget::Box.new \
  name: "helloworld box", # Symbolic name
  top: "center",          # Can also be of format 10, "50%", or "50%+-10"
  left: "center",         # Can also be of format 10, "50%", or "50%+-10"
  width: 20,              # Can also be of format 10, "50%", or "50%+-10"
  height: 5,              # Can also be of format 10, "50%", or "50%+-10"
  content: "{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
  parse_tags: true,       # Parse {} tags within content (default already is true)
  style: C::Style.new(fg: "yellow", bg: "blue", border: true)

screen.append hello

# When ctrl-q or q is pressed, exit.
# (We can do this by listening for C::Event::KeyPress::CtrlQ specifically,
# or for all C::Event::KeyPress and then checking the value of `e.char`.)
screen.on(C::Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    screen.destroy
    exit
  end
end

screen.exec
```

## Screenshots

Animated demo (examples/tech-demo.cr)

![Crysterm Demo Video](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/2020-01-29-1.gif)

Layout engine (showing inline/masonry layout, test/widget-layout.cr)

![Crysterm Masonry Layout](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/layout.png)

Transparency, color blending, and shadow (part of small-tests/shadow.cr)

![Crysterm Color Blending](https://raw.githubusercontent.com/crystallabs/crysterm/master/screenshots/shadow.png)

## Development

### Introduction

Crysterm is inspired by Blessed, Blessed-contrib, and Qt.

Blessed is a large, self-contained framework. Its author
implemented many prerequisites, including an event model (a modified copy of an early Node.js
EventEmitter), complete termcap/terminfo system (an
alternative to ncurses), mouse support, Unicode handling, color manipulation routines, etc.,
all bundled with blessed.

In Crysterm, the equivalents have been created as individual shards for the ecosystem's
benefit. The event model is in 
[event_handler](https://github.com/crystallabs/event_handler), color routines in
[term_colors](https://github.com/crystallabs/term_colors), terminal handling in
[tput.cr](https://github.com/crystallabs/tput.cr), GPM mouse in
[gpm.cr](https://github.com/crystallabs/gpm.cr), a terminfo library in
[unibilium.cr](https://github.com/crystallabs/unibilium.cr), and an animated PNG/GIF parser
in [pnggif](https://github.com/crystallabs/pnggif).


### Terminal Handling

Complete terminal handling is implemented in [tput.cr](https://github.com/crystallabs/tput.cr).

Tput uses unibilium.cr, bindings for terminfo library called [unibilium](https://github.com/neovim/unibilium/), now maintained by Neovim.
Unibilium is packaged for a good number of operating systems and only requires the library, not headers.
However, tput also has a standard, hardcoded mode which can be used when one does not wish to use unibilium or terminfo.
(A lot of modern software just hardcodes the sequences.)

### Event model

Event model is at the core of Crysterm, implemented via [event_handler](https://github.com/crystallabs/event_handler).

Please refer to [event_handler](https://github.com/crystallabs/event_handler)'s documentation for all usage instructions.

The events used by Crysterm and its widgets are defined in `src/event.cr`.

### Testing

Run `crystal spec` as usual.

### Documentation

Run `crystal docs` as usual.

## Thanks

* All the fine folks in the [Crystal community](https://crystal-lang.org/community/).

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
