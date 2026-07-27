# Shared `TerminalEmulator` spec harness, hoisted out of the 7 spec files that
# each defined a byte-identical (modulo the `cols` default and a `cell_char`/
# `row` naming split) copy: spec/terminal_emulator_spec.cr,
# bugs11_terminal_emulator_spec.cr, bugs12_terminal_emulator_spec.cr,
# bugs13_wtop_terminal_emulator_spec.cr, bugs15_emulator_spec.cr,
# bugs15_emulator_strings_spec.cr, group_f_terminal_emulator_spec.cr.
#
# NOT shared here: bugs3_terminal_spec.cr's typed variant, which reads
# `em.ybase` (the live-viewport base) instead of `em.ydisp` (the scrolled
# display offset) -- a different offset, kept local by design.

EMU_DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

def emu(cols = 10, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, EMU_DFL)
end

# Char of cell `x` on row `y`.
def emu_char(em, x, y)
  em.lines[em.ydisp + y][x].char
end

# The visible text of row `y` (wide-glyph continuation NULs dropped, trailing
# blanks stripped). Verified byte-identical in effect between
# terminal_emulator_spec.cr and group_f_terminal_emulator_spec.cr (their NUL
# char literals differ only in spelling, same char value) -- the only two
# files defining a `row` helper.
def emu_row(em, y)
  em.lines[em.ydisp + y].map(&.char).join.delete(NUL).rstrip
end

private NUL = 0.chr
