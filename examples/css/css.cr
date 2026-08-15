require "../../src/crysterm"

# FEATURE: styling an app from a CSS stylesheet instead of inline `Style.new`.
#
# One stylesheet string styles the whole widget tree: type selectors
# (`Button`), descendant selectors (`Box Button`), and interaction states
# (`Button:focus`) — the cascade re-runs automatically as focus moves. The
# engine also understands Qt's QSS dialect directly (see tests/misc/themes.cr
# for unmodified desktop themes), any Crysterm app accepts
# `--colors-stylesheet FILE` out of the box, and `window.load_stylesheet path`
# + `window.watch_stylesheet` give file loading with live hot-reload.
#
# Run with:  crystal examples/css/css.cr

include Crysterm
include Crysterm::Widgets

window = Window.new title: "CSS demo"

window.stylesheet = <<-CSS
  Box {
    border: solid;
    border-color: #57c7ff;
    padding: 1;
    background-color: #282a2e;
    color: #c5c8c6;
  }
  Label { color: #8abeb7; }
  Button {
    background-color: #373b41;
    color: #c5c8c6;
    border: solid;
  }
  Button:focus {
    background-color: #57c7ff;
    color: #1d1f21;
  }
  CSS

# (`Widget::Box`, not bare `Box` — that name is taken by Crystal's stdlib.)
card = Widget::Box.new parent: window, top: :center, left: :center, width: 44, height: 12

Label.new parent: card, top: 0, left: 0, width: "100%", height: 2, parse_tags: true,
  content: "{center}Everything here is styled by the\nstylesheet — no Style.new anywhere.{/center}"

Label.new parent: card, top: 3, left: 0, width: "100%", height: 1, parse_tags: true,
  content: "{center}Tab between the buttons: :focus restyles.{/center}"

Button.new parent: card, top: 5, left: 4, width: 12, height: 3, content: "One"
Button.new parent: card, top: 5, left: 24, width: 12, height: 3, content: "Two"

# `q` / Ctrl-Q quit by default. Run the main loop:
window.exec
