# FEATURE: hardware & artificial cursors, per-window and per-widget.
#
# A `Window` carries a default cursor; any widget can override its shape,
# blink and color while focused (`Widget#set_cursor`, `#cursor_color=`).
# When the terminal's hardware cursor can't express a request — or with
# shape `:none`, a fully custom glyph — Crysterm draws an "artificial"
# cursor, composited into the cell buffer itself, so it shows up even in
# headless captures and recordings. Focus cycles across the four fields
# below to show each override in turn.

require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Cursors"

# Backdrop and caption.
CW::Box.new parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: CT::Style.new(bg: "#1a1b26")
CW::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Hardware & artificial cursors — per-widget shape, blink, color and custom glyphs{/center}",
  parse_tags: true, style: CT::Style.new(fg: "white", bg: "#202830")
CW::Box.new parent: s, top: 2, left: "center", width: 72, height: 2,
  content: "{center}Styled shapes use the terminal's hardware cursor when it can comply;\n" \
           "otherwise Crysterm composites an artificial cursor into the cells.{/center}",
  parse_tags: true, style: CT::Style.new(fg: "#565f89", bg: "#1a1b26")

# One LineEdit per cursor override; the border label names the override.
fields = [] of CW::LineEdit
mk_field = ->(top : Int32, label : String, value : String) do
  w = CW::LineEdit.new parent: s, top: top, left: "center", width: 52, height: 3,
    label: label,
    style: CT::Style.new(fg: "#c0caf5", bg: "#1f2335", border: CT::Border.new(fg: "#3b4261"))
  w.value = value
  fields << w
  w
end

# (a) The classic blinking block.
a = mk_field.call 5, " set_cursor :block, blink: true ", "A blinking block cursor"
a.set_cursor :block, blink: true

# (b) Underline shape, recolored.
b = mk_field.call 9, " :underline + cursor_color ", "An orange underline cursor"
b.cursor_shape = :underline
b.cursor_color = "#ff8800"

# (c) A thin bar ("beam"), in another color.
c = mk_field.call 13, " :line + cursor_color ", "A cyan bar cursor"
c.set_cursor :line
c.cursor_color = "#7dcfff"

# (d) Shape :none = fully custom artificial cursor: the glyph and colors
# come from the cursor's own `Style`, drawn by Crysterm rather than the
# terminal — so it also appears in this demo's captures.
d = mk_field.call 17, " :none — custom artificial glyph ", "A custom-glyph artificial cursor"
d.set_cursor :none
d.ensure_cursor.style = CT::Style.new(fill_char: '▚', fg: "#e0af68", bg: "#414868")

CW::Box.new parent: s, top: 21, left: 0, width: "100%", height: 1,
  content: "{center}Focus (and with it the active cursor) moves to the next field every 1.2 s{/center}",
  parse_tags: true, style: CT::Style.new(fg: "#565f89", bg: "#1a1b26")

# Start on the custom artificial cursor (it is composited into the cells,
# so it shows even in single-frame captures), then cycle focus so each
# field's cursor takes effect in turn.
idx = fields.size - 1
fields[idx].focus
s.every(1.2.seconds) do
  fields[idx].focus
  idx = (idx + 1) % fields.size
end

s.exec
