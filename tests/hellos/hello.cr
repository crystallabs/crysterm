# The "Hello world" from README.md: one window, one styled box.
require "../../src/crysterm"

# The two conventional short aliases — nothing is `include`d into your namespace.
alias CT = Crysterm
alias CW = Crysterm::Widgets

# A `Window` is the surface your widgets live on.
window = CT::Window.new title: "hello"

# `tagged:` is `content:` with the {tags} parsed.
CW::Box.new \
  parent: window,
  top: :center, left: :center, width: 20, height: 5,
  tagged: "{center}'Hello {bold}world{/bold}!'\nPress q to quit.{/center}",
  style: CT::Style.new(fg: "yellow", bg: "blue", border: true)

# `q` / Ctrl-Q quit by default. Run the main loop:
window.exec
