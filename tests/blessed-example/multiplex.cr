require "../../src/crysterm"

# Port of blessed's `example/multiplex.js`.
#
# A 2x2 grid of terminal-emulator widgets, each running its own shell. You can:
#   * type into the focused terminal,
#   * drag a terminal around by its body (Crysterm's `enable_drag`),
#   * click a terminal to focus it,
#   * Shift-Tab to cycle focus,
#   * Ctrl-Q to kill all the shells and quit.
#
# A shell's window title (OSC 0/2) updates the terminal's label
# (`Event::SetContent`, new title in `terminal.title`).

include Crysterm

screen = Window.new title: "multiplex.cr", dock_borders: true
screen.enable_mouse

screen.stylesheet = <<-CSS
  Terminal        { border: solid; }
  Terminal:focus  { border-color: green; }
CSS

topleft = Widget::Terminal.new(
  parent: screen, cursor_shape: :line,
  label: " multiplex.cr ",
  left: 0, top: 0, width: "50%", height: "50%",
)

topright = Widget::Terminal.new(
  parent: screen, cursor_shape: :block,
  label: " multiplex.cr ",
  left: "50%", top: 0, width: "50%", height: "50%",
)

bottomleft = Widget::Terminal.new(
  parent: screen, cursor_shape: :block,
  label: " multiplex.cr ",
  left: 0, top: "50%", width: "50%", height: "50%",
)

bottomright = Widget::Terminal.new(
  parent: screen, cursor_shape: :block,
  label: " multiplex.cr ",
  left: "50%", top: "50%", width: "50%", height: "50%",
)

terminals = [topleft, topright, bottomleft, bottomright]

terminals.each do |term|
  term.enable_drag
  # Reflect the child's window title on the label.
  term.on(Event::SetContent) do
    if title = term.title
      screen.title = title
      term.set_label " #{title} "
      screen.render
    end
  end
  # Click to focus.
  term.on(Event::Click) { term.focus }
end

topleft.focus

screen.on(Event::KeyPress) do |e|
  if e.key == Tput::Key::CtrlQ
    terminals.each &.kill
    screen.destroy
    exit 0
  elsif e.key == Tput::Key::ShiftTab
    screen.focus_next
    screen.render
  end
end

screen.exec
