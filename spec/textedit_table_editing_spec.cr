require "./spec_helper"

include Crysterm

# In-table editing in `Widget::TextEdit` (TEXTEDIT.md follow-up): editing
# keys become cell operations while the caret is inside a table — typing/
# Backspace/Delete edit the cell (padding re-rendered), Tab/Shift-Tab move
# between cells (Tab past the last cell appends a row), Enter inserts a row
# — and the guards that keep outside edits from tearing the box.

private GFM = "| Name | N |\n| --- | ---: |\n| ab | 1 |\n| c | 22 |"

private def te_screen(width = 40, height = 12)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def table_te(s, md = GFM)
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 12
  te.set_markdown md
  s._render
  tf = te.document.blocks[0].block_format.table_format.not_nil!
  {te, TextTable.new(te.document, tf)}
end

private def key(te, k : ::Tput::Key)
  te._listener Crysterm::Event::KeyPress.new '\0', k
end

private def type(te, text : String)
  text.each_char { |c| te._listener Crysterm::Event::KeyPress.new(c) }
end

describe Widget::TextEdit do
  describe "in-table editing" do
    it "types into the caret's cell, caret following" do
      s = te_screen
      te, tbl = table_te s
      r = tbl.cell_text_range(1, 0).not_nil!
      te.cursor_pos = r.end # after "ab"
      type te, "c"
      tbl.cell_text(1, 0).should eq "abc"
      te.cursor_pos.should eq tbl.cell_text_range(1, 0).not_nil!.end
      type te, "d"
      tbl.cell_text(1, 0).should eq "abcd"
      # Mid-cell insert.
      te.cursor_pos = tbl.cell_text_range(1, 0).not_nil!.begin + 1
      type te, "X"
      tbl.cell_text(1, 0).should eq "aXbcd"
      te.cursor_pos.should eq tbl.cell_text_range(1, 0).not_nil!.begin + 2
    end

    it "Backspace/Delete stay within the cell" do
      s = te_screen
      te, tbl = table_te s
      r = tbl.cell_text_range(2, 1).not_nil! # "22"
      te.cursor_pos = r.end
      key te, ::Tput::Key::Backspace
      tbl.cell_text(2, 1).should eq "2"
      # At cell start, Backspace is absorbed (no join into the border).
      te.cursor_pos = tbl.cell_text_range(2, 1).not_nil!.begin
      key te, ::Tput::Key::Backspace
      tbl.cell_text(2, 1).should eq "2"
      te.document.block_count.should eq 6
      # Delete removes forward within the cell, absorbed at its end.
      key te, ::Tput::Key::Delete
      tbl.cell_text(2, 1).should eq ""
      key te, ::Tput::Key::Delete
      te.document.block_count.should eq 6
    end

    it "Tab and Shift-Tab move between cells, wrapping rows" do
      s = te_screen
      te, tbl = table_te s
      te.cursor_pos = tbl.cell_text_range(0, 0).not_nil!.begin
      key te, ::Tput::Key::Tab
      tbl.cell_at(te.cursor_pos).should eq({0, 1})
      key te, ::Tput::Key::Tab # wraps to the next row
      tbl.cell_at(te.cursor_pos).should eq({1, 0})
      key te, ::Tput::Key::ShiftTab
      tbl.cell_at(te.cursor_pos).should eq({0, 1})
    end

    it "Tab past the last cell appends a row (Qt behavior)" do
      s = te_screen
      te, tbl = table_te s
      te.cursor_pos = tbl.cell_text_range(2, 1).not_nil!.end
      key te, ::Tput::Key::Tab
      tbl.rows.should eq 4
      tbl.cell_at(te.cursor_pos).should eq({3, 0})
    end

    it "Enter inserts a row below the caret's" do
      s = te_screen
      te, tbl = table_te s
      te.cursor_pos = tbl.cell_text_range(1, 1).not_nil!.begin
      key te, ::Tput::Key::Enter
      tbl.rows.should eq 4
      tbl.cell_text(2, 0).should eq ""
      tbl.cell_text(3, 0).should eq "c" # old row 2 pushed down
      tbl.cell_at(te.cursor_pos).should eq({2, 0})
    end

    it "absorbs kill/yank/paste keys inside a table" do
      s = te_screen
      te, tbl = table_te s
      before = te.value
      te.cursor_pos = tbl.cell_text_range(1, 0).not_nil!.end
      key te, ::Tput::Key::CtrlK
      key te, ::Tput::Key::CtrlU
      key te, ::Tput::Key::CtrlY
      key te, ::Tput::Key::CtrlV
      te.value.should eq before
    end

    it "undo reverts one cell keystroke" do
      s = te_screen
      te, tbl = table_te s
      before = te.value
      te.cursor_pos = tbl.cell_text_range(1, 0).not_nil!.end
      type te, "z"
      tbl.cell_text(1, 0).should eq "abz"
      key te, ::Tput::Key::CtrlZ
      te.value.should eq before
    end
  end

  describe "table guards from outside" do
    it "Backspace right below a table does not join into the border" do
      s = te_screen
      te, _ = table_te s, GFM + "\n\nafter"
      # Caret at the start of the trailing "after" block.
      bi = te.document.block_count - 1
      te.cursor_pos = te.document.block_position(bi)
      before = te.value
      key te, ::Tput::Key::Backspace
      te.value.should eq before
    end

    it "blocks typing over a selection that overlaps the table" do
      s = te_screen
      te, tbl = table_te s
      r = tbl.cell_text_range(1, 0).not_nil!
      te.selection_anchor = 0
      te.cursor_pos = r.end
      before = te.value
      type te, "x"
      te.value.should eq before
    end
  end
end
