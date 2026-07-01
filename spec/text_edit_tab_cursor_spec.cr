require "./spec_helper"

include Crysterm

# A TAB is a single char in the editable buffer (`@value`) but renders as
# `tab_char * tab_size` (default 4 spaces) in the wrapped lines (`@_clines`).
# The caret model maps between the two; treating rendered columns as raw
# `@value` codepoints shifts the caret left by `tab_size - 1` per TAB, enough
# to land Up/Down on the wrong character or logical line.
private def te_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

describe "PlainTextEdit caret with TABs" do
  it "moves Up onto the visually-aligned position of the line above (across a TAB)" do
    s = te_screen
    pte = Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 20, height: 10
    # Line 0 "ab\tcd" renders as "ab    cd" (8 cols); line 1 "XYZWVUT" (7 cols).
    pte.value = "ab\tcd\nXYZWVUT"
    pte.cursor_pos = pte.value.size # end of line 1 (rendered col 7)

    pte._listener Crysterm::Event::KeyPress.new('\0', Tput::Key::Up)

    # Rendered col 7 on "ab    cd" is the 'd'; the editable offset just before 'd'
    # in "ab\tcd" (a,b,\t,c,d) is index 4 — on the FIRST logical line.
    first_nl = pte.value.index!('\n')
    pte.cursor_pos.should be < first_nl
    pte.cursor_pos.should eq 4
  end
end
