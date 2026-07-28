# The "Hello world" from README.md: one window, one styled box.
require "../../src/crysterm"

alias C = Crysterm

# A `Window` is the surface your widgets live on.
window = C::Window.new title: "hello"

C::Widget::Box.new \
  parent: window,
  top: "center", left: "center", width: 20, height: 5,
  content: "{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
  parse_tags: true,
  style: C::Style.new(fg: "yellow", bg: "blue", border: true)

# `q` / Ctrl-Q quit by default. Run the main loop:
window.exec
