require "./spec_helper"

include Crysterm

# `Widget::TextEdit` rendering: document fragments written directly into the
# cell buffer with packed attributes (TEXTEDIT.md Phase 2). Headless harness
# like `text_editing_keys_spec.cr`: a `Window` over in-memory IOs and a
# synchronous `Window#repaint` (NOT `#render`, which only rings the async
# render-loop doorbell), then cells asserted straight off `Window#lines`.

private def te_screen(width = 40, height = 8)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def new_te(s, content = "")
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8, content: content
  s.repaint
  te
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
  it "renders plain document text into cells" do
    s = te_screen
    new_te s, "hello world"
    row_text(s, 0, 11).should eq "hello world"
  end

  it "renders one block per line" do
    s = te_screen
    new_te s, "one\ntwo\nthree"
    row_text(s, 0, 3).should eq "one"
    row_text(s, 1, 3).should eq "two"
    row_text(s, 2, 5).should eq "three"
  end

  it "renders a char format run with its packed attributes (bold + fg)" do
    s = te_screen
    te = new_te s, "hello world"
    te.document.apply_char_format(0, 5, TextCharFormat.new(bold: true, fg: 0xFF0000))
    s.repaint

    a = s.lines[0][0].attr
    (Attr.flags(a) & Attr::BOLD).should_not eq 0
    Attr.fg(a).should eq Attr.pack_color(0xFF0000)

    # Past the run: default attributes again.
    a2 = s.lines[0][6].attr
    (Attr.flags(a2) & Attr::BOLD).should eq 0
    Attr.fg(a2).should eq Attr.pack_color(-1)
  end

  it "renders underline/italic/strike/inverse flags" do
    s = te_screen
    te = new_te s, "abcd"
    te.document.apply_char_format(0, 1, TextCharFormat.new(underline: true))
    te.document.apply_char_format(1, 2, TextCharFormat.new(italic: true))
    te.document.apply_char_format(2, 3, TextCharFormat.new(strike: true))
    te.document.apply_char_format(3, 4, TextCharFormat.new(inverse: true))
    s.repaint

    (Attr.flags(s.lines[0][0].attr) & Attr::UNDERLINE).should_not eq 0
    (Attr.flags(s.lines[0][1].attr) & Attr::ITALIC).should_not eq 0
    (Attr.flags(s.lines[0][2].attr) & Attr::STRIKE).should_not eq 0
    (Attr.flags(s.lines[0][3].attr) & Attr::REVERSE).should_not eq 0
  end

  it "renders an anchor underlined" do
    s = te_screen
    te = new_te s, "link here"
    te.document.apply_char_format(0, 4, TextCharFormat.new(anchor_href: "https://example.org"))
    s.repaint
    (Attr.flags(s.lines[0][0].attr) & Attr::UNDERLINE).should_not eq 0
    (Attr.flags(s.lines[0][5].attr) & Attr::UNDERLINE).should eq 0
  end

  it "renders a heading block bold" do
    s = te_screen
    te = new_te s, "Title\nbody"
    te.document.apply_block_format(0, 0, TextBlockFormat.new(heading_level: 1))
    s.repaint
    (Attr.flags(s.lines[0][0].attr) & Attr::BOLD).should_not eq 0
    (Attr.flags(s.lines[1][0].attr) & Attr::BOLD).should eq 0
  end

  it "extends a block background across the full row, past the text" do
    s = te_screen
    te = new_te s, "bg\nplain"
    te.document.apply_block_format(0, 0, TextBlockFormat.new(bg: 0x0000FF))
    s.repaint
    Attr.bg(s.lines[0][0].attr).should eq Attr.pack_color(0x0000FF)
    # Trailing cell far past the two chars of text:
    Attr.bg(s.lines[0][20].attr).should eq Attr.pack_color(0x0000FF)
    # The other block is untouched:
    Attr.bg(s.lines[1][0].attr).should eq Attr.pack_color(-1)
  end

  it "keeps formats attached to their text across edits before them" do
    s = te_screen
    te = new_te s, "hello world"
    te.document.apply_char_format(6, 11, TextCharFormat.new(bold: true))

    # Insert at the start through the editing path (shared mixin op).
    te.cursor_pos = 0
    te._listener key('X')
    te.value.should eq "Xhello world"
    s.repaint

    # The bold run moved right with its text.
    (Attr.flags(s.lines[0][7].attr) & Attr::BOLD).should_not eq 0
    (Attr.flags(s.lines[0][0].attr) & Attr::BOLD).should eq 0
  end

  it "typing with a typing format inserts formatted text" do
    s = te_screen
    te = new_te s, ""
    te.merge_current_char_format TextCharFormat.new(bold: true)
    te._listener key('b')
    te._listener key('o')
    s.repaint

    te.value.should eq "bo"
    (Attr.flags(s.lines[0][0].attr) & Attr::BOLD).should_not eq 0
    (Attr.flags(s.lines[0][1].attr) & Attr::BOLD).should_not eq 0
    # The document itself carries the format (not just the paint):
    te.document.char_format_at(1).bold?.should be_true
  end

  it "renders TABs expanded to the style's tab width" do
    s = te_screen
    te = new_te s, ""
    te.value = "a\tb"
    s.repaint
    ts = te.style.tab_size
    row_text(s, 0, 2 + ts).should eq "a" + (te.style.tab_char * ts) + "b"
  end

  it "two views share one document" do
    s = te_screen(60, 12)
    doc = TextDocument.new("shared")
    te1 = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 30, height: 4, document: doc
    te2 = Widget::TextEdit.new parent: s, left: 0, top: 5, width: 30, height: 4, document: doc
    s.repaint

    te1.cursor_pos = doc.size
    te1._listener key('!')
    te1.value.should eq "shared!"
    te2.value.should eq "shared!"

    s.repaint
    row_text(s, 0, 7).should eq "shared!"
    row_text(s, 5, 7).should eq "shared!"
  end
end
