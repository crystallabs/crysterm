require "./spec_helper"

include Crysterm

# `Widget::TextEdit` Phase 4 structures rendering (TEXTEDIT.md): list
# markers, quote bars, horizontal rules, block indent/alignment/margins —
# all as decoration columns/rows outside the document's positions — and the
# shared caret/mouse geometry staying exact through the per-row offsets.

private def te_screen(width = 40, height = 8)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def new_te(s, content = "", width = 40, height = 8)
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: width, height: height, content: content
  s._render
  te
end

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def row_text(s, y, len)
  String.build do |io|
    len.times { |x| io << s.lines[y][x].char }
  end
end

private def select_all_list(te, style : TextListFormat::Style)
  c = te.text_cursor
  c.select :document
  c.create_list(style)
end

describe Widget::TextEdit do
  describe "lists" do
    it "renders bullet markers before each item" do
      s = te_screen
      te = new_te s, "one\ntwo"
      select_all_list(te, :disc)
      s._render
      row_text(s, 0, 5).should eq "• one"
      row_text(s, 1, 5).should eq "• two"
    end

    it "renders checkbox markers for a GFM task list" do
      s = te_screen
      te = new_te s
      te.set_markdown "- [x] done\n- [ ] todo"
      s._render
      row_text(s, 0, 8).should eq "[x] done"
      row_text(s, 1, 8).should eq "[ ] todo"
    end

    it "renders decimal markers numbered in document order" do
      s = te_screen
      te = new_te s, "a\nb\nc"
      select_all_list(te, :decimal)
      s._render
      row_text(s, 0, 4).should eq "1. a"
      row_text(s, 2, 4).should eq "3. c"
    end

    it "renumbers when an earlier item is deleted" do
      s = te_screen
      te = new_te s, "a\nb\nc"
      select_all_list(te, :decimal)
      s._render
      te.document.remove(0, 2) # "a\n" gone
      s._render
      row_text(s, 0, 4).should eq "1. b"
      row_text(s, 1, 4).should eq "2. c"
    end

    it "indents nested lists by their level" do
      s = te_screen
      te = new_te s, "outer\ninner"
      c = te.text_cursor
      c.set_position(0)
      c.create_list(TextListFormat.new(style: :disc, indent: 1))
      c.set_position(6)
      c.create_list(TextListFormat.new(style: :disc, indent: 2))
      s._render
      row_text(s, 0, 7).should eq "• outer"
      row_text(s, 1, 9).should eq "  • inner"
    end

    it "wraps item text within the marker indent, continuation rows aligned" do
      s = te_screen
      te = new_te s, "aaaa bbbb cccc", 12, 6
      select_all_list(te, :disc)
      s._render
      row_text(s, 0, 6).should eq "• aaaa"
      # Continuation row: no marker, text starts at the same column.
      te._clines.size.should be > 1
      row_text(s, 1, 6).should eq "  bbbb"
    end

    it "keeps mouse position mapping exact past the marker" do
      s = te_screen
      te = new_te s, "one\ntwo"
      select_all_list(te, :decimal)
      s._render
      # Click on the 'n' of "one" — drawn at x = 3 (after "1. ") + 1.
      te.position_at(4, 0).should eq 1
      # Click on the marker itself maps to the line start.
      te.position_at(0, 0).should eq 0
    end
  end

  describe "imported markdown" do
    it "renders structural decorations end to end" do
      s = te_screen
      te = new_te s
      te.set_markdown "- one\n- two\n\n> quoted\n\n---"
      s._render
      row_text(s, 0, 5).should eq "• one"
      row_text(s, 1, 5).should eq "• two"
      row_text(s, 3, 8).should eq "│ quoted"
      row_text(s, 5, 10).should eq "─" * 10
    end
  end

  describe "quotes and rules" do
    it "renders quote bars per level" do
      s = te_screen
      te = new_te s, "quoted\ndeep"
      te.document.apply_block_format(0, 0, TextBlockFormat.new(quote_level: 1))
      te.document.apply_block_format(7, 7, TextBlockFormat.new(quote_level: 2))
      s._render
      row_text(s, 0, 8).should eq "│ quoted"
      row_text(s, 1, 8).should eq "│ │ deep"
    end

    it "renders a horizontal-rule block as a full-width glyph fill" do
      s = te_screen
      te = new_te s, "above\n\nbelow"
      te.document.apply_block_format(6, 6, TextBlockFormat.new(horizontal_rule: true))
      s._render
      row_text(s, 1, 40).should eq "─" * 40
      row_text(s, 2, 5).should eq "below"
    end
  end

  describe "indent, alignment, margins" do
    it "indents a block by its indent cells" do
      s = te_screen
      te = new_te s, "moved"
      te.document.apply_block_format(0, 0, TextBlockFormat.new(indent: 3))
      s._render
      row_text(s, 0, 8).should eq "   moved"
    end

    it "centers and right-aligns block rows" do
      s = te_screen
      te = new_te s, "mid\nend", 10, 4
      te.document.apply_block_format(0, 0, TextBlockFormat.new(alignment: Tput::AlignFlag::HCenter))
      te.document.apply_block_format(4, 4, TextBlockFormat.new(alignment: Tput::AlignFlag::Right))
      s._render
      # Content width is 10 minus the scrollbar/caret margin; the exact
      # column comes from the same math the layout used.
      r0 = row_text(s, 0, 10)
      r0.strip.should eq "mid"
      r0.index!("mid").should be > 0
      r1 = row_text(s, 1, 10)
      r1.strip.should eq "end"
      r1.index!("end").should be >= r0.index!("mid")
    end

    it "renders top/bottom margins as blank rows and maps them to the block" do
      s = te_screen
      te = new_te s, "aaa\nbbb"
      te.document.apply_block_format(4, 4, TextBlockFormat.new(top_margin: 1))
      s._render
      row_text(s, 0, 3).should eq "aaa"
      row_text(s, 1, 3).should eq "   "
      row_text(s, 2, 3).should eq "bbb"
      te._clines.size.should eq 3
    end

    it "steps the caret over margin rows on Down/Up" do
      s = te_screen
      te = new_te s, "aaa\nbbb"
      te.document.apply_block_format(4, 4, TextBlockFormat.new(top_margin: 1))
      s._render
      te.cursor_pos = 1
      te._listener ctl(::Tput::Key::Down)
      te.cursor_pos.should eq 5 # "b|bb", column kept
      te._listener ctl(::Tput::Key::Up)
      te.cursor_pos.should eq 1
    end

    it "selection highlight lands on the shifted columns" do
      s = te_screen
      te = new_te s, "sel"
      te.document.apply_block_format(0, 0, TextBlockFormat.new(indent: 2))
      s._render
      te.selection_anchor = 0
      te.cursor_pos = 3
      s._render
      (Attr.flags(s.lines[0][2].attr) & Attr::REVERSE).should_not eq 0
      (Attr.flags(s.lines[0][0].attr) & Attr::REVERSE).should eq 0
    end
  end
end
