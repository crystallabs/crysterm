[![Build Status](https://travis-ci.com/crystallabs/crysterm.svg?branch=master)](https://travis-ci.com/crystallabs/crysterm)
[![Version](https://img.shields.io/github/tag/crystallabs/crysterm.svg?maxAge=360)](https://github.com/crystallabs/crysterm/releases/latest)
[![License](https://img.shields.io/github/license/crystallabs/crysterm.svg)](https://github.com/crystallabs/crysterm/blob/master/LICENSE)

# Crysterm

Crysterm is a console/terminal toolkit for Crystal.

It tries to follow closely the implementation and behavior of the libraries that inspired it,
[Blessed](https://github.com/chjj/blessed) and [Blessed-contrib](https://github.com/yaronn/blessed-contrib)
for Node.js. However, being implemented in Crystal (a proper OO language), it tries to use the language's
best practices, avoid bugs and problems found from Blessed, and also (especially in the future) incorporate
some aspects of [Qt](https://doc.qt.io/).

## Trying it out

```
git clone https://github.com/crystallabs/crysterm
cd crysterm
shards --ignore-crystal-version

crystal examples/hello.cr
crystal examples/hello2.cr
crystal examples/tech-demo.cr
```

(If you get an Exception trying to run the "tech-demo" example, maximize your terminal window and try
again.)

## Screenshots

Animated demo
![Crysterm Demo Video](https://raw.githubusercontent.com/docelic/crysterm/master/screenshots/2020-01-29-1.gif)

Transparency, color blending
![Crysterm Color Blending](https://raw.githubusercontent.com/docelic/crysterm/master/screenshots/transparency.png)

Layout engine (masonry layout)
![Crysterm Masonry Layout](https://raw.githubusercontent.com/docelic/crysterm/master/screenshots/layout.png)

## User Manual

### Event model

Event model is at the very core of the Crysterm library.

The basic class `Event` and system's built-in events come from the `event_handler` shard.

The necessary additional events used by built-in widgets are defined in `src/events.cr`.

The final event module (mixin) named `EventHandler` also comes from the `event_handler` shard. It provides all the macros and functions needed for a class to be event-enabled, that is, to accept event handlers and emit events.
Every class that wants to emit its events needs to `include EventHandler`.

For more information about the event model, please see https://github.com/crystallabs/event_handler.

### Class hierarchy

Class `Event` represents the parent class of all events.

Module `EventHandler` adds methods for adding and removing event handlers, and emitting events.

Basic crysterm class `Node` includes `EventHandler`.

Class `Screen` (of which there can be multiple in a running application) inherits from `Node`.

Class `Element` inherits from `Node`.

All other widgets, including layouts, inherit from `Element` or some of its subclasses such as `Box` or `List`.

(NOTE: Currently `Screen` does not inherit from `Element`, yet it behaves in some aspects as one,
and also in a hierarchy chain it is a `@parent` of all elements on it (in addition to also being
set as `@screen` on every element in it). This should be improved so that `Screen` is not a
parent of `Element`s.)

### Drawing

Crysterm does not use ncurses. It uses its own functionality to detect term characteristics, parse terminfo,
and configure the program to output correct escape sequences for the current terminal.

The renderer makes use of CSR (change-scroll-region) and BCE (back-color-erase). It draws the screen using
the painter's algorithm, with smart cursor movements and screen damage buffer.
Only the change (damage) is updated on the screen. All optimizations can be enabled/disabled via options.

### Text Attributes

Generally speaking, to define foreground and background colors and attributes for strings, one can embed
appropriate escape sequences into the strings themselves or use Crystal's `Colorize` module.

Crysterm is interoperable with those two approaches, but also implements its own concept of "tags" in strings,
such as "{lightblue-fg} text in light blue {/lightblue-fg}". Tags can be embedded in strings directly, applied
from a Hash with `generate_tags`, and removed from a string with `strip_tags` or `clean_tags`.
Any existing strings where "{}" should not be interpreted can be protected with `escape_tags`.

### Roadmap

Currently the basics of everything are working, as seen in the demo.

The roadmap, roughly:

1. Improve API (minimal amount of code to do things, sane defaults, etc.)
1. Improve keyboard support (if/when necessary, seems OK for now)
1. Gradually support mouse
1. Support reading values from terminals
1. Probably more things

### Testing

Run `crystal spec` as usual.

### Documentation

Run `crystal docs` as usual.

## Thanks

* All the fine folks on FreeNode IRC channel #crystal-lang and on Crystal's Gitter channel https://gitter.im/crystal-lang/crystal

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
- https://github.com/ndudnicz/selenite - Color representation convertion methods (rgb, hsv, hsl, ...) for Crystal
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
