# Shared `Window` grid readback helpers, hoisted out of the ~40 spec files that
# each redefined "char/fg/bg at a cell" and "row y as a String" against
# `Window#lines` -- often under the same name with a transposed argument order
# (`(y, x)` in about half of them), which made a copied assertion silently read
# the wrong cell.
#
# Everything here is standardized on `(x, y)` -- column first, row second.
#
# NOT here (kept local by design):
#   * `TerminalEmulator` readbacks -- those live on the `emu_*` names in
#     spec/support/emulator_helpers.cr (ydisp-based) or stay file-local when
#     they read `em.ybase` instead, so window and emulator indexing can never
#     be confused.
#   * whole-screen dumps that map NUL to a space and/or join with newlines
#     (`text_of`/`rows`/`cells_text`/...), and readbacks with defensive
#     `lines[y][x]?` fallbacks -- different semantics, left in their files.

# Char of the cell at column *x*, row *y*.
def cell_char(s, x, y)
  s.lines[y][x].char
end

# Unpacked foreground color of the cell at column *x*, row *y*.
def cell_fg(s, x, y)
  Crysterm::Attr.unpack_color(Crysterm::Attr.fg(s.lines[y][x].attr))
end

# Unpacked background color of the cell at column *x*, row *y*.
def cell_bg(s, x, y)
  Crysterm::Attr.unpack_color(Crysterm::Attr.bg(s.lines[y][x].attr))
end

# Row *y* as a String. With *range* given, exactly those columns, verbatim;
# without it, the whole row with trailing blanks stripped.
def row_text(s, y, range : Range(Int32, Int32)? = nil)
  row = s.lines[y]
  if range
    String.build { |io| range.each { |x| io << row[x].char } }
  else
    String.build { |io| (0...row.size).each { |x| io << row[x].char } }.rstrip
  end
end
