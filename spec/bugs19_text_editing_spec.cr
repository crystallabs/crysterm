require "./spec_helper"

include Crysterm

# Table-cell editing against a cell whose text carries Unicode whitespace
# `TextTable.split_data_row` strips but `TextTable#cell_text_range` doesn't
# (only ASCII spaces); pasted-text CR/CRLF normalization shared by
# `PlainTextEdit`/`LineEdit`; and routing a bracketed-paste insert through
# the cell API when the caret sits inside a table so it doesn't tear the
# pre-rendered row.

private GFM = "| Name | N |\n| --- | ---: |\n| ab | 1 |\n| c | 22 |"

private def table_te(s, md = GFM)
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 12
  te.set_markdown md
  s.repaint
  tf = te.document.blocks[0].block_format.table_format.not_nil!
  {te, TextTable.new(te.document, tf)}
end

describe "table-cell edits against Unicode-whitespace cell edges" do
  it "types at the end of a cell with a leading ideographic space (U+3000) without corrupting or raising" do
    s = headless_screen(40, 12, default_quit_keys: true)
    te, tbl = table_te s
    tbl.set_cell_text(1, 0, "　ab")
    r = tbl.cell_text_range(1, 0).not_nil!
    te.cursor_pos = r.end
    te._listener Crysterm::Event::KeyPress.new('X')
    new_r = tbl.cell_text_range(1, 0).not_nil!
    te.document.plain_text(new_r.begin, new_r.end).should eq "　abX"
    te.cursor_pos.should eq new_r.end
  end

  it "types at the end of a cell with a leading no-break space (NBSP) without corrupting or raising" do
    s = headless_screen(40, 12, default_quit_keys: true)
    te, tbl = table_te s
    tbl.set_cell_text(1, 0, " ab")
    r = tbl.cell_text_range(1, 0).not_nil!
    te.cursor_pos = r.end
    te._listener Crysterm::Event::KeyPress.new('X')
    new_r = tbl.cell_text_range(1, 0).not_nil!
    te.document.plain_text(new_r.begin, new_r.end).should eq " abX"
  end

  it "Backspace at the end of a cell with a leading ideographic space removes the last real char, not the space" do
    s = headless_screen(40, 12, default_quit_keys: true)
    te, tbl = table_te s
    tbl.set_cell_text(1, 0, "　ab")
    r = tbl.cell_text_range(1, 0).not_nil!
    te.cursor_pos = r.end
    te._listener Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Backspace)
    new_r = tbl.cell_text_range(1, 0).not_nil!
    te.document.plain_text(new_r.begin, new_r.end).should eq "　a"
  end
end

describe "pasted-text line-ending normalization" do
  it "PlainTextEdit turns a CRLF paste into two lines with no \\r" do
    s = headless_screen(60, 24, default_quit_keys: true)
    pte = Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 40, height: 6
    pte.emit Crysterm::Event::Paste.new("one\r\ntwo")
    pte.value.should eq "one\ntwo"
    pte.value.includes?('\r').should be_false
    pte.document.block_count.should eq 2
  end

  it "PlainTextEdit turns a bare-CR paste into two lines with no \\r" do
    s = headless_screen(60, 24, default_quit_keys: true)
    pte = Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 40, height: 6
    pte.emit Crysterm::Event::Paste.new("one\rtwo")
    pte.value.should eq "one\ntwo"
    pte.value.includes?('\r').should be_false
    pte.document.block_count.should eq 2
  end

  it "LineEdit#submit hands off a single spaced line with no \\r after a CRLF paste" do
    s = headless_screen(60, 24, default_quit_keys: true)
    # `input_on_focus: false`: the default would auto-start a callback-less
    # read on construction (the first keyable widget is auto-focused), and
    # `#read_input`'s `@_reading` guard would then ignore the block below —
    # see `Widget::InputDialog`, which drives reading explicitly for the
    # same reason.
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 30, height: 1, input_on_focus: false
    result = nil.as(String?)
    le.read_input { |v| result = v }
    le.emit Crysterm::Event::Paste.new("one\r\ntwo")
    le.submit
    result.should eq "one two"
    result.not_nil!.includes?('\r').should be_false
  end

  it "LineEdit#submit hands off a single spaced line with no \\r after a bare-CR paste" do
    s = headless_screen(60, 24, default_quit_keys: true)
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 30, height: 1, input_on_focus: false
    result = nil.as(String?)
    le.read_input { |v| result = v }
    le.emit Crysterm::Event::Paste.new("one\rtwo")
    le.submit
    result.should eq "one two"
    result.not_nil!.includes?('\r').should be_false
  end
end

describe "bracketed paste with the caret inside a table cell" do
  it "lands the pasted text in the cell instead of tearing the row" do
    s = headless_screen(40, 12, default_quit_keys: true)
    te, tbl = table_te s
    before_rows = tbl.rows
    before_blocks = te.document.block_count
    r = tbl.cell_text_range(1, 0).not_nil! # "ab"
    te.cursor_pos = r.begin + 1            # between 'a' and 'b'
    te.emit Crysterm::Event::Paste.new("X\nY")
    tbl.cell_text(1, 0).should eq "aX Yb"
    tbl.rows.should eq before_rows
    te.document.block_count.should eq before_blocks
    # The other cell/rows are untouched.
    tbl.cell_text(1, 1).should eq "1"
    tbl.cell_text(2, 0).should eq "c"
  end

  it "a paste that would tear a CRLF-carrying clipboard still lands as one cell edit" do
    s = headless_screen(40, 12, default_quit_keys: true)
    te, tbl = table_te s
    before_rows = tbl.rows
    before_blocks = te.document.block_count
    r = tbl.cell_text_range(2, 0).not_nil! # "c"
    te.cursor_pos = r.end
    te.emit Crysterm::Event::Paste.new("one\r\ntwo")
    tbl.cell_text(2, 0).should eq "cone two"
    tbl.rows.should eq before_rows
    te.document.block_count.should eq before_blocks
  end
end
