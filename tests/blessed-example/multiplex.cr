require "../../src/crysterm"

# Port of blessed's `example/multiplex.js`.
#
# A 2x2 grid of terminal-emulator widgets, each running its own shell. You can:
#   * type into the focused terminal,
#   * drag a terminal around by its body (Crysterm's `draggable`),
#   * click a terminal to focus it,
#   * Shift-Tab to cycle focus,
#   * Ctrl-Q to kill all the shells and quit.
#
# A shell's window title (OSC 0/2) updates the terminal's label
# (`CT::Event::ContentSet`, new title in `terminal.title`).

alias CT = Crysterm
alias CW = CT::Widgets

window = CT::Window.new title: "multiplex.cr", border_junctions: true
window.enable_mouse

window.stylesheet = <<-CSS
  Terminal        { border: solid; }
  Terminal:focus  { border-color: green; }
CSS

topleft = CW::Terminal.new(
  parent: window, cursor_shape: :line,
  label: " multiplex.cr ",
  left: 0, top: 0, width: "50%", height: "50%",
)

topright = CW::Terminal.new(
  parent: window, cursor_shape: :block,
  label: " multiplex.cr ",
  left: "50%", top: 0, width: "50%", height: "50%",
)

bottomleft = CW::Terminal.new(
  parent: window, cursor_shape: :block,
  label: " multiplex.cr ",
  left: 0, top: "50%", width: "50%", height: "50%",
)

bottomright = CW::Terminal.new(
  parent: window, cursor_shape: :block,
  label: " multiplex.cr ",
  left: "50%", top: "50%", width: "50%", height: "50%",
)

terminals = [topleft, topright, bottomleft, bottomright]

terminals.each do |term|
  term.draggable = true
  # Reflect the child's window title on the label.
  term.on(CT::Event::ContentSet) do
    if title = term.title
      window.title = title
      term.label = " #{title} "
    end
  end
  # Click to focus.
  term.on(CT::Event::Click) { term.focus }
end

topleft.focus

window.on(CT::Event::KeyPress) do |e|
  if e.key == Tput::Key::CtrlQ
    terminals.each &.kill
    window.quit
  elsif e.key == Tput::Key::ShiftTab
    window.focus_next
  end
end

window.exec
