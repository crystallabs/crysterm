# The "Hello world" from README.md: one window, one styled box.
require "../../src/crysterm"

include Crysterm
include Crysterm::Widgets

# A `Window` is the surface your widgets live on.
window = Window.new title: "hello"

# (`Widget::Box`, not bare `Box` — that name is taken by Crystal's stdlib;
# most other widgets are directly visible through `include Crysterm::Widgets`.)
Widget::Box.new \
  parent: window,
  top: :center, left: :center, width: 20, height: 5,
  content: "{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
  parse_tags: true,
  style: Style.new(fg: "yellow", bg: "blue", border: true)

# `q` / Ctrl-Q quit by default. Run the main loop:
window.exec
