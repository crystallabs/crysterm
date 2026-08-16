require "./spec_helper"

include Crysterm

# Text-system parity sweep: block handles and the
# `BlockLocation` record, `TextDocument#cursor` construction, the
# `typing_format_at`/`char_format_of` split, cursor-inserted tables and tags,
# the undo-recording switch, the document theme, overlay writes bumping the
# revision, the widget-safe tags export, and the editing widgets' text
# signals (`TextEdited`/`CursorPositionChanged`/`SelectionChanged`).

describe "TextDocument#block_at / #find_block handles" do
  it "block_at returns a named BlockLocation" do
    doc = TextDocument.new("ab\ncd")
    loc = doc.block_at(4)
    loc.index.should eq 1
    loc.offset.should eq 1
  end

  it "find_block returns a navigable handle" do
    doc = TextDocument.new("one\ntwo\nthree")
    b = doc.find_block(5) # inside "two"
    b.text.should eq "two"
    b.block_number.should eq 1
    b.position.should eq 4
    b.document.try(&.same?(doc)).should be_true
    b.next.try(&.text).should eq "three"
    b.previous.try(&.text).should eq "one"
    doc.find_block(0).previous.nil?.should be_true
    doc.find_block(doc.size).next.nil?.should be_true
  end

  it "a detached block has no document" do
    TextBlock.new("x").document.nil?.should be_true
  end

  it "handles stay valid across edits (identity-based)" do
    doc = TextDocument.new("one\ntwo")
    b = doc.find_block(5) # "two"
    doc.cursor(0).insert_text("zero\n")
    b.block_number.should eq 2
    b.position.should eq 9
  end
end

describe "TextDocument size vocabulary" do
  it "character_count aliases size; empty? reflects a blank document" do
    doc = TextDocument.new("ab\ncd")
    doc.character_count.should eq doc.size
    doc.empty?.should be_false
    TextDocument.new.empty?.should be_true
  end
end

describe "typing_format_at vs char_format_of" do
  it "typing format reads before the position, char_format_of at it" do
    doc = TextDocument.new
    doc.cursor(0).insert_text("ab", TextCharFormat.new(bold: true))
    doc.cursor(2).insert_text("cd", TextCharFormat.new(italic: true))
    doc.typing_format_at(2).bold?.should be_true        # the char before pos 2 ('b')
    doc.char_format_of(2).try(&.italic?).should be_true # 'c' itself
    doc.char_format_of(doc.size).nil?.should be_true
  end

  it "char_format_of is nil on the block separator" do
    doc = TextDocument.new("a\nb")
    doc.char_format_of(1).nil?.should be_true
  end
end

describe "TextDocument#cursor construction" do
  it "builds plain and selecting cursors" do
    doc = TextDocument.new("hello")
    c = doc.cursor(2)
    c.position.should eq 2
    c.anchor.should eq 2
    sel = doc.cursor(1, 4)
    sel.selection?.should be_true
    sel.selected_text.should eq "ell"
  end
end

describe "TextCursor#insert_tags" do
  it "inserts the home format like insert_html/insert_markdown" do
    doc = TextDocument.new
    doc.cursor(0).insert_tags("{bold}hi{/bold} there")
    doc.to_plain_text.should eq "hi there"
    doc.char_format_of(0).try(&.bold?).should be_true
    doc.char_format_of(4).try(&.bold?).should be_false
  end
end

describe "TextCursor#insert_table / #current_table" do
  it "inserts an empty grid and finds it from within" do
    doc = TextDocument.new
    table = doc.cursor(0).insert_table(3, 2)
    table.rows.should eq 3
    table.columns.should eq 2
    r = table.cell_text_range(1, 0) || raise "no cell range"
    doc.cursor(r.begin).current_table.try(&.format.same?(table.format)).should be_true
    TextDocument.new("x").cursor(0).current_table.nil?.should be_true
  end

  it "takes content, edits cells, and undoes as one step" do
    doc = TextDocument.new("intro")
    table = doc.cursor(doc.size).insert_table(["H1", "H2"], [["a", "b"]])
    table.cell_text(0, 0).should eq "H1"
    table.cell_text(1, 1).should eq "b"
    table.set_cell_text(1, 0, "aa").should be_true
    table.cell_text(1, 0).should eq "aa"
    doc.undo.should be_true # the cell edit
    doc.undo.should be_true # the whole insertion
    doc.to_plain_text.should eq "intro"
  end
end

describe "TextDocument#undo_redo_enabled" do
  it "suppresses recording and clears the stack when disabled" do
    doc = TextDocument.new("a")
    doc.cursor(1).insert_text("b")
    doc.undo_available?.should be_true
    doc.undo_redo_enabled = false
    doc.undo_available?.should be_false
    doc.cursor(2).insert_text("c")
    doc.undo_available?.should be_false
    doc.undo.should be_false
    doc.to_plain_text.should eq "abc"
    doc.undo_redo_enabled = true
    doc.cursor(3).insert_text("d")
    doc.undo.should be_true
    doc.to_plain_text.should eq "abc"
  end
end

describe "TextDocument#theme" do
  it "markdown= imports with the document's own theme" do
    themed = TextDocument.new
    themed.theme = TextTheme.new(heading_color: 0x123456)
    plain = TextDocument.new
    themed.markdown = "# Title"
    plain.markdown = "# Title"
    themed_fg = themed.char_format_of(0).try(&.fg)
    plain_fg = plain.char_format_of(0).try(&.fg)
    themed_fg.should_not eq plain_fg
    themed_fg.should eq 0x123456
  end
end

describe "interchange setters return the assigned value" do
  it "set_plain_text/set_tags return their input" do
    doc = TextDocument.new
    doc.set_plain_text("x").should eq "x"
    doc.set_tags("{bold}y{/bold}").should eq "{bold}y{/bold}"
    (doc.plain_text = "z").should eq "z"
  end
end

describe "overlay writes bump the document revision" do
  it "user_state=/additional_formats= are revision-visible and change-guarded" do
    doc = TextDocument.new("ab")
    b = doc.blocks[0]
    rev = doc.revision
    b.user_state = 7
    doc.revision.should be > rev
    rev2 = doc.revision
    b.user_state = 7 # no change — no bump
    doc.revision.should eq rev2
    b.additional_formats = [{0, 1, TextCharFormat.new(bold: true)}] of {Int32, Int32, TextCharFormat}
    doc.revision.should be > rev2
    rev3 = doc.revision
    b.additional_formats = [{0, 1, TextCharFormat.new(bold: true)}] of {Int32, Int32, TextCharFormat} # equal — no bump
    doc.revision.should eq rev3
  end
end

describe "widget-safe tags export" do
  it "expand_tags drops {link=…}/{/link} instead of leaking them" do
    doc = TextDocument.new
    doc.cursor(0).insert_tags("see {link=https://x.io}docs{/link} now")
    tags = doc.to_tags
    tags.should contain "{link=" # the document round-trip keeps the anchor
    box = Widget::Box.new parent: headless_screen(default_quit_keys: true)
    box.parse_tags = true
    out = box.expand_tags(tags)
    out.should contain "docs"
    out.should_not contain "link="
    out.should_not contain "{link"
  end
end

describe "text editing signals" do
  it "LineEdit emits TextEdited on typing but not on value=" do
    s = headless_screen(80, 24)
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
    s.repaint
    edited = [] of String
    changed = [] of String
    le.on(Event::TextEdited) { |e| edited << e.value }
    le.on(Event::TextChanged) { |e| changed << e.value }
    le.focus
    le.emit kp('h')
    le.emit kp('i')
    edited.should eq ["h", "hi"]
    le.value = "reset"
    changed.last.should eq "reset"
    edited.should eq ["h", "hi"] # a programmatic set is not an edit
  end

  it "emits CursorPositionChanged for keys and programmatic moves" do
    s = headless_screen(80, 24)
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
    s.repaint
    positions = [] of Int32
    le.on(Event::CursorPositionChanged) { |e| positions << e.position }
    le.focus
    le.emit kp('a')
    le.emit kp('b')
    le.emit kp('\0', Tput::Key::Left)
    positions.should eq [1, 2, 1]
    le.cursor_position = 0
    positions.last.should eq 0
  end

  it "emits SelectionChanged when the selection appears and collapses" do
    s = headless_screen(80, 24)
    le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
    s.repaint
    sel_events = 0
    le.on(Event::SelectionChanged) { sel_events += 1 }
    le.focus
    le.emit kp('a')
    le.emit kp('b')
    sel_events.should eq 0
    le.select_all
    sel_events.should eq 1
    le.emit kp('\0', Tput::Key::Left) # collapses the selection
    sel_events.should eq 2
  end
end
