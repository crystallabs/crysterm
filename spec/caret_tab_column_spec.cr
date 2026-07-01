require "./spec_helper"

include Crysterm

# `Mixin::TextEditing#caret_display_column` (places the terminal cursor on the
# non-wrapping editing path, e.g. a horizontally-scrolling `PlainTextEdit`)
# must measure the caret against the same TAB-expanded content the renderer
# shows (see `process_content`). Using the raw codepoint offset instead would
# under-count the column by `tab_size - 1` per TAB before the caret.
describe "Mixin::TextEditing caret column with TABs" do
  it "places the caret using the rendered TAB expansion, not the raw offset" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)

    pte = Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 40, height: 5
    pte.wrap_content = false # non-wrapping (caret_display_column) path
    pte.style.tab_size = 4
    pte.style.tab_char = " "
    pte.value = "a\tb"
    pte.focus
    s.render

    pte.cursor_pos = 3 # caret at the end of "a\tb"
    pte._update_cursor

    # Rendered line is "a" + 4 spaces + "b" -> column 6, not 3 (raw TAB width).
    s.tput.cursor.x.should eq 6
  end
end
