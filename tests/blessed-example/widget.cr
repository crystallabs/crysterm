require "../../src/crysterm"

# Port of blessed's `example/widget.js`.
#
# A single centered Box that reacts to the mouse and keyboard:
#   * click it -> content changes,
#   * press Enter while focused -> different content, plus a set/insert line demo,
#   * q / Escape / Ctrl-C quits.

include Crysterm
include Crysterm::Widgets

window = Window.new title: "widget.cr"

# Box centered horizontally and vertically.
box = Widget::Box.new(
  parent: window,
  top: "center",
  left: "center",
  width: "50%",
  height: "50%",
  content: "Hello {bold}world{/bold}!",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "magenta", border: true),
)

# Change content on click.
box.on(Event::Click) do
  box.content = "{center}Some different {red-fg}content{/red-fg}.{/center}"
end

# Handle Enter when focused.
box.on(Event::KeyPress) do |e|
  if e.key == Tput::Key::Enter
    box.content = "{right}Even different {black-fg}content{/black-fg}.{/right}\n"
    box.replace_line 1, "bar"
    box.insert_line 1, "foo"
  end
end

# Quit on Escape, q, or Ctrl-C.
window.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::Escape || e.key == Tput::Key::CtrlC
    window.quit
  end
end

box.focus

window.exec
