Crysterm is a console/terminal toolkit for Crystal, inspired by 
[Blessed](https://github.com/chjj/blessed), [Blessed-contrib](https://github.com/yaronn/blessed-contrib), and
[Qt](https://doc.qt.io/).

Advanced features:

![Pine — a full terminal email-client clone](examples/pine/pine.5s.apng)

![Qt-modeled widgets showcase](tests/misc/qt_widgets.5s.apng)

![Minesweeper](examples/games/minesweeper/minesweeper.5s.apng)

![Matrix effect](tests/widget/effect/matrix/matrix.5s.apng)

![Plasma effect (truecolor)](tests/widget/effect/plasma/plasma.5s.apng)

![Fire effect](tests/widget/effect/fire/fire.5s.apng)

![Unicode rendering](tests/blessed-test/widget-unicode.5s.apng)

Image-rendering backends — an image drawn straight into the terminal:

![In-terminal image](tests/blessed-test/widget-image.5s.apng)

Crysterm can render images through a real terminal graphics protocol (overlay
via w3m / überzug, Sixel, Kitty, iTerm2, ReGIS, and Tektronix 4014) or
down-sample them to text using Unicode glyph mosaics (block, half, quadrant,
sextant, octant, braille, ASCII) and ANSI 16/256-color or truecolor cells.

## Tech intro

Crysterm is supported by the event model in 
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

(And other examples from directories `examples/` and `tests/`.)

## Testing

Run `crystal spec` as usual.

## Documentation

Run `crystal docs` as usual.

## Thanks

* All the fine folks in the [Crystal community](https://crystal-lang.org/community/).
