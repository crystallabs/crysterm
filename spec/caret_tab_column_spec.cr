require "./spec_helper"

include Crysterm

# `Mixin::TextEditing#caret_display_column` (used to place the terminal cursor on
# the non-wrapping editing path, e.g. a horizontally-scrolling `PlainTextEdit`)
# must measure the caret column against the SAME content the renderer shows. The
# content has TABs expanded to `tab_char * tab_size` (see `process_content`), so
# a caret sitting after a TAB belongs in the expanded column, not the raw
# codepoint offset — otherwise every TAB before the caret under-counts the column
# by `tab_size - 1` and the cursor drifts left of (and out of sync with) the text.
describe "Mixin::TextEditing caret column with TABs" do
  it "places the caret using the rendered TAB expansion, not the raw offset" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)

    pte = Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 40, height: 5
    pte.wrap_content = false # engage the non-wrapping (caret_display_column) path
    pte.style.tab_size = 4
    pte.style.tab_char = " "
    pte.value = "a\tb"
    pte.focus
    s.render

    pte.cursor_pos = 3 # caret at the end of "a\tb"
    pte._update_cursor

    # Rendered line is "a" + 4 spaces + "b", so the end caret sits in column 6 —
    # not column 3 (which would treat the TAB as a single column).
    s.tput.cursor.x.should eq 6
  end
end
