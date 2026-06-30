require "../../src/crysterm"

# Port of blessed's `example/widget.js`.
#
# A single centered Box that reacts to the mouse and the keyboard:
#   * click it  -> its content changes,
#   * press Enter while it's focused -> different content, plus a set/insert
#     line demonstration,
#   * q / Escape / Ctrl-C quits.
#
# Crysterm uses the very same `{tag}` markup as blessed (`{bold}`, `{center}`,
# `{red-fg}`, ...), so the content strings carry over unchanged.

include Crysterm

screen = Window.new title: "widget.cr"

# A box perfectly centered horizontally and vertically.
box = Widget::Box.new(
  parent: screen,
  top: "center",
  left: "center",
  width: "50%",
  height: "50%",
  content: "Hello {bold}world{/bold}!",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "magenta", border: true),
)

# If our box is clicked, change the content.
box.on(Event::Click) do
  box.set_content "{center}Some different {red-fg}content{/red-fg}.{/center}"
  screen.render
end

# If the box is focused, handle Enter and give us some more content.
box.on(Event::KeyPress) do |e|
  if e.key == Tput::Key::Enter
    box.set_content "{right}Even different {black-fg}content{/black-fg}.{/right}\n"
    box.set_line 1, "bar"
    box.insert_line 1, "foo"
    screen.render
  end
end

# Quit on Escape, q, or Ctrl-C.
screen.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::Escape || e.key == Tput::Key::CtrlC
    screen.destroy
    exit 0
  end
end

# Focus our element.
box.focus

screen.exec
