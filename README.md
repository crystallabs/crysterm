[![Linux CI](https://github.com/crystallabs/crysterm/workflows/Linux%20CI/badge.svg)](https://github.com/crystallabs/crysterm/actions?query=workflow%3A%22Linux+CI%22+event%3Apush+branch%3Amaster)
[![Version](https://img.shields.io/github/tag/crystallabs/crysterm.svg?maxAge=360)](https://github.com/crystallabs/crysterm/releases/latest)
[![License](https://img.shields.io/github/license/crystallabs/crysterm.svg)](https://github.com/crystallabs/crysterm/blob/master/LICENSE)

Crysterm is a console/terminal toolkit for Crystal, inspired heavily by 
[Blessed](https://github.com/chjj/blessed), [Blessed-contrib](https://github.com/yaronn/blessed-contrib), and
[Qt](https://doc.qt.io/).

Advanced features:

![](screenshots/features/truecolor.gif)

![](screenshots/features/styling.gif)

![](screenshots/features/matrix.gif)

![](screenshots/features/concurrent_rendering.gif)

![](screenshots/features/image.gif)

![](screenshots/features/netscape.gif)

![](screenshots/features/unicode.gif)

![](screenshots/features/widgets.gif)

Image-rendering backends:

![](screenshots/features/matterhorn-overlay.png)

Sixel:

![](screenshots/features/matterhorn-sixel.png)

![](screenshots/features/matterhorn-kitty.png)

iTerm2:

![](screenshots/features/matterhorn-iterm.png)

![](screenshots/features/matterhorn-octant.png)

![](screenshots/features/matterhorn-sextant.png)

![](screenshots/features/matterhorn-quadrant.png)

![](screenshots/features/matterhorn-half.png)

![](screenshots/features/matterhorn-ascii.png)

![](screenshots/features/matterhorn-block.png)

![](screenshots/features/matterhorn-ansi-c256.png)

![](screenshots/features/matterhorn-ansi-c16.png)

![](screenshots/features/matterhorn-braille.png)

![](screenshots/features/matterhorn-regis.png)

Tektronix 4014:

![](screenshots/features/matterhorn-tek.png)

## Tech intro

It is supported by the event model in 
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
through which all app events and input are routed.

In-depth introductory doc is in [USAGE.md](https://github.com/crystallabs/crysterm/blob/master/USAGE.md).

## Examples

```
git clone https://github.com/crystallabs/crysterm
cd crysterm
shards

crystal examples/hello.cr
crystal examples/hello2.cr
crystal examples/tech-demo.cr
```

(And other examples from directories `examples/`, `small-tests/`, `test/` and `test-auto/`.)

## Testing

Run `crystal spec` as usual.

## Documentation

Run `crystal docs` as usual.

## Thanks

* All the fine folks in the [Crystal community](https://crystal-lang.org/community/).

## Other projects

List of other at least somewhat-related projects in no particular order:

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
