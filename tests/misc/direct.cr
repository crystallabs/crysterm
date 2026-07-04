# FEATURE: direct mode — inline styled output, no full-screen takeover.
#
# `Crysterm::Direct` is the notcurses direct-mode analogue: it emits color,
# text attributes, cursor moves and box drawing into a NORMAL scrolling
# terminal — no alternate buffer, no cell buffer, no render loop. It reuses the
# same color/SGR down-reduction pipeline as the full-screen renderer, so a
# 16-/256-color terminal still gets a faithful palette.
#
# Unlike the other demos here it doesn't call `Window#exec`; the caller drives
# output and we flush. `output: STDOUT` is passed explicitly so it emits even
# when run non-interactively (a bare `Direct.new` follows `headless?` and would
# sink to memory when piped).

require "../../src/crysterm"

include Crysterm

d = Direct.new output: STDOUT

# Styled spans — each self-contained (SGR + reset), so following text is clean.
d.print "hello, ", fg: "green", bold: true
d.print "colored ", fg: 0xff8800, italic: true
d.print "world", fg: "white", bg: 0x2050a0, underline: true
d.newline 2

# Text attributes.
d.print "bold ", bold: true
d.print "underline ", underline: true
d.print "reverse ", reverse: true
d.print "strike", strike: true
d.newline 2

# 24-bit color ramp — each swatch is a truecolor background, reduced
# automatically on terminals that can't do TrueColor.
16.times do |i|
  r = (i * 16)
  d.print " ", bg: (r << 16) | (0x40 << 8) | (0xff - r)
end
d.newline 2

# Box drawing at absolute positions, plus a horizontal rule.
d.print "boxes:"
d.newline
d.box d.dim_y - 6, 2, 4, 20, fg: "cyan"
d.box d.dim_y - 6, 26, 4, 20, fg: "magenta", ascii: true
d.move_yx d.dim_y - 1, 0
d.hline 46, fg: "yellow"

# Leave styling clean and flush.
d.newline
d.print "dims: #{d.dim_x}x#{d.dim_y}\n", fg: "green"
d.reset
