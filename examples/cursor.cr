require "../src/crysterm"

# Artificial cursor demo.
#
# Crysterm can draw the cursor itself ("artificial" cursor) instead of relying
# on the terminal's hardware cursor. This mirrors blessed's artificial cursor
# (see blessed `test/widget.js`, which starts with
# `cursor: { artificial: true, shape: 'line', blink: true }`).
#
# An artificial cursor is painted into the rendered buffer at the terminal
# cursor position by `Screen#draw`. The supported shapes are:
#
#   l -> line       (renders as a │ glyph)
#   u -> underline  (underlined cell)
#   b -> block      (inverted cell)
#   c -> custom     (CursorShape::None: the cursor's own glyph + colors)
#
# `None` is the equivalent of blessed's fully custom ("object") cursor: instead
# of a predefined shape, the cursor is drawn from its `style` (here a magenta
# `▮` on yellow). See `spec/cursor_spec.cr` and `documentation/decorations.md`.
#
# Move the cursor with the arrow keys; press l/u/b/c to switch shape; q to quit.

class CursorDemo
  include Crysterm
  include Tput::Namespace

  s = Screen.new title: "Artificial cursor demo"

  # Enable the artificial (Crysterm-drawn) cursor, line-shaped and blinking,
  # just like blessed's demo.
  s.cursor.artificial = true
  s.cursor.shape = CursorShape::Line
  s.cursor.blink = true
  s.show_cursor

  Widget::Box.new \
    parent: s,
    top: "center",
    left: "center",
    width: 44,
    height: 7,
    content: "Artificial cursor demo\n\n" \
             "Arrow keys: move    l/u/b: line/underline/block\n" \
             "q or Ctrl-Q: quit",
    style: Style.new(fg: "white", bg: "blue", border: true)

  # Start the cursor somewhere visible and paint the first frame.
  x = s.awidth // 2
  y = s.aheight // 2
  s.tput.cursor_pos y, x
  s.render

  move = ->(dx : Int32, dy : Int32) do
    x = (x + dx).clamp(0, s.awidth - 1)
    y = (y + dy).clamp(0, s.aheight - 1)
    s.tput.cursor_pos y, x
    s.render
  end

  s.on(Event::KeyPress) do |e|
    case
    when e.char == 'q', e.key == Tput::Key::CtrlQ
      s.destroy
      exit
    when e.char == 'l' then s.cursor.shape = CursorShape::Line; s.render
    when e.char == 'u' then s.cursor.shape = CursorShape::Underline; s.render
    when e.char == 'b' then s.cursor.shape = CursorShape::Block; s.render
    when e.char == 'c'
      # Custom cursor: a magenta '▮' on a yellow cell.
      s.cursor.shape = CursorShape::None
      s.cursor.style.char = '▮'
      s.cursor.style.fg = "magenta"
      s.cursor.style.bg = "yellow"
      s.render
    when e.key == Tput::Key::Up    then move.call(0, -1)
    when e.key == Tput::Key::Down  then move.call(0, 1)
    when e.key == Tput::Key::Left  then move.call(-1, 0)
    when e.key == Tput::Key::Right then move.call(1, 0)
    end
  end

  s.exec
end
