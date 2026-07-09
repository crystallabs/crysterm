require "./spec_helper"

include Crysterm

# `Widget::TextEdit` layout: per-block wrapping into display rows, cache
# invalidation on document edits, undo/redo through the editing keys, and
# the caret geometry shared with `PlainTextEdit` via `Mixin::TextEditing`
# running over the `DocumentBuffer` adapter (TEXTEDIT.md Phase 2 / §5).

private def te_screen(width = 40, height = 8)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def key(char : Char, k : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, k
end

private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def row_text(s, y, len)
  String.build do |io|
    len.times { |x| io << s.lines[y][x].char }
  end
end

describe Widget::TextEdit do
  it "wraps a long block into several display rows" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 12, height: 6,
      content: "aaaa bbbb cccc"
    s._render

    te._clines.size.should be > 1
    # The rows join back (modulo the wrap cuts) to the block's text.
    te._clines.lines.join.gsub(/ +/, " ").strip.should eq "aaaa bbbb cccc"
  end

  it "maps the caret through wrapped rows (Up/Down keep the column)" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "one\ntwo\nthree"
    s._render

    te.cursor_pos = te.value.size # end of "three"
    te._listener ctl(::Tput::Key::Up)
    # Landed on "two" (block above), column clamped to its width.
    te.cursor_pos.should eq te.value.index!("two") + 3
    te._listener ctl(::Tput::Key::Down)
    te.cursor_pos.should eq te.value.size
  end

  it "Enter splits a block; Backspace at block start joins" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "abcd"
    s._render

    te.cursor_pos = 2
    te._listener key('\n', ::Tput::Key::Enter)
    te.value.should eq "ab\ncd"
    te.document.block_count.should eq 2

    # Caret ended after the separator (start of the new block).
    te.cursor_pos.should eq 3

    te._listener ctl(::Tput::Key::Backspace)
    te.value.should eq "abcd"
    te.document.block_count.should eq 1
    te.cursor_pos.should eq 2
  end

  it "keeps other blocks' cached rows across an edit (layout stays correct)" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8,
      content: "first\nsecond\nthird"
    s._render

    te.cursor_pos = te.value.index!("second")
    te._listener key('X')
    te.value.should eq "first\nXsecond\nthird"
    s._render

    row_text(s, 0, 5).should eq "first"
    row_text(s, 1, 7).should eq "Xsecond"
    row_text(s, 2, 5).should eq "third"
  end

  it "undoes and redoes typing as coalesced steps with caret placement (C-z / M-z)" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "base"
    s._render

    te.cursor_pos = 4
    te._listener key('1')
    te._listener key('2')
    te._listener key('3')
    te.value.should eq "base123"

    te._listener ctl(::Tput::Key::CtrlZ)
    te.value.should eq "base"
    te.cursor_pos.should eq 4

    te._listener ctl(::Tput::Key::AltZ)
    te.value.should eq "base123"
    te.cursor_pos.should eq 7
  end

  it "undo restores deleted text (Backspace run) and formats survive" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "bold text"
    te.document.apply_char_format(0, 4, TextCharFormat.new(bold: true))
    s._render

    te.cursor_pos = 4
    3.times { te._listener ctl(::Tput::Key::Backspace) }
    te.value.should eq "b text"

    te._listener ctl(::Tput::Key::CtrlZ) # undo the backspace run (one step)
    te.value.should eq "bold text"
    te.document.char_format_at(3).bold?.should be_true
  end

  it "emits TextChange on edits and on undo" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6, content: ""
    s._render

    changes = [] of String
    te.on(Crysterm::Event::TextChange) { |e| changes << e.value }

    te._listener key('a')
    te._listener ctl(::Tput::Key::CtrlZ)
    changes.should eq ["a", ""]
  end

  it "value= replaces the whole content, clears undo, and parks the caret at the end" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "old"
    s._render

    te._listener key('x')
    te.value = "brand new"
    te.value.should eq "brand new"
    te.cursor_pos.should eq 9
    te.document.undo_available?.should be_false
    s._render
    row_text(s, 0, 9).should eq "brand new"
  end

  it "honors max_length through the document adapter" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "12345", max_length: 6
    s._render

    te.cursor_pos = 5
    te._listener key('6')
    te._listener key('7')
    te.value.should eq "123456"
  end

  it "read_only blocks edits but allows caret movement" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "fixed", read_only: true
    s._render

    te.cursor_pos = 5
    te._listener key('X')
    te._listener ctl(::Tput::Key::Backspace)
    te._listener ctl(::Tput::Key::CtrlZ)
    te.value.should eq "fixed"

    te._listener ctl(::Tput::Key::Left)
    te.cursor_pos.should eq 4
  end

  it "kill and yank work over the document (C-k / C-y)" do
    s = te_screen
    before_rl = Crysterm::Config.input_readline_keys
    begin
      Crysterm::Config.input_readline_keys = true
      te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
        content: "keep cut"
      te.kill_ring = Crysterm::KillRing.new
      s._render

      te.cursor_pos = 4
      te._listener ctl(::Tput::Key::CtrlK)
      te.value.should eq "keep"

      te._listener ctl(::Tput::Key::CtrlY)
      te.value.should eq "keep cut"
    ensure
      Crysterm::Config.input_readline_keys = before_rl
    end
  end

  it "grows and shrinks the wrapped row count as blocks change" do
    s = te_screen
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6,
      content: "a"
    s._render
    te._clines.size.should eq 1

    te.cursor_pos = 1
    te._listener key('\n', ::Tput::Key::Enter)
    te._listener key('b')
    s._render
    te._clines.size.should eq 2

    te._listener ctl(::Tput::Key::Backspace)
    te._listener ctl(::Tput::Key::Backspace)
    s._render
    te._clines.size.should eq 1
  end
end
