require "../../src/crysterm"

# Port of blessed's `example/index.js`.
#
# blessed's `index.js` drives the terminal through the low-level `program`
# object (no widgets). In Crysterm that same low-level surface lives on the
# `Screen` and its `tput` (the alternate buffer, cursor moves, charset,
# mouse/focus reporting, ...), with raw SGR written straight to `screen.output`
# — exactly what `program.write`/`program.bg` did in blessed.
#
# What it does: enters the alternate buffer, enables mouse + focus reporting,
# draws a couple of coloured strings and a line-drawing-charset alphabet, then
# echoes every mouse / focus / blur event along the bottom row. Press q to quit.

include Crysterm

# We render the terminal ourselves (no widget tree), so turn off the built-in
# quit-key handler — q is handled below with an explicit teardown, like blessed.
screen = Window.new title: "index.cr", default_quit_keys: false

out = screen.output
write = ->(s : String) { out.print s; out.flush }

# keypress: q tears the terminal back down and exits.
screen.on(Event::KeyPress) do |e|
  if e.char == 'q'
    screen.tput.clear
    screen.disable_mouse
    screen.tput.show_cursor
    screen.tput.normal_buffer
    screen.tput.flush
    exit 0
  end
end

# Moves to the bottom row and clears it (the status line).
status = ->(msg : String) {
  screen.tput.cursor_pos(screen.aheight - 1, 0)
  screen.tput.erase_in_line # default: erase to the right
  write.call msg
}

# mouse / focus / blur all arrive as Event::Mouse (focus reporting reuses the
# same channel — see Tput::Mouse::Action::Focus/Blur).
screen.on(Event::Mouse) do |e|
  case e.action
  when .focus?
    status.call "Gained focus."
  when .blur?
    status.call "Lost focus."
  when .up?
    # mouseup: ignored, as in the original.
  else
    msg =
      if e.action.wheel_up?
        "Mouse wheel up at: #{e.x}, #{e.y}"
      elsif e.action.wheel_down?
        "Mouse wheel down at: #{e.x}, #{e.y}"
      elsif e.action.down? && e.button.left?
        "Left button down at: #{e.x}, #{e.y}"
      elsif e.action.down? && e.button.right?
        "Right button down at: #{e.x}, #{e.y}"
      else
        "Mouse at: #{e.x}, #{e.y}"
      end
    status.call msg
    # Mark the pointer cell with a red background space.
    screen.tput.cursor_pos(e.y, e.x)
    write.call "\e[41m \e[49m"
  end
end

# Enter the alternate buffer and draw the static content.
screen.tput.alternate_buffer
screen.tput.hide_cursor
screen.tput.clear

screen.tput.cursor_pos(0, 0)
write.call "\e[40m\e[34mHello world\e[39m" # blue fg on black bg

col = (screen.awidth // 2) - 4
screen.tput.cursor_pos(5, col)
write.call "Hi again!\e[49m" # reset background ('!black')

# Switch to the DEC line-drawing charset, print the alphabet (which renders as
# box-drawing glyphs), then switch back.
screen.tput.cursor_pos(7, 0)
screen.tput.charset = Tput::Namespace::Charset::SCLD
write.call "abcdefghijklmnopqrstuvwxyz0123456789"
screen.tput.charset = Tput::Namespace::Charset::US

screen.tput.flush

# Start the input fibers (establishes raw mode), then turn on mouse + focus
# reporting — after raw mode, so the enable sequences aren't echoed.
screen.listen
screen.tput.enable_mouse(focus: true)

sleep
