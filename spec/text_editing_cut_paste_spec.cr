require "./spec_helper"

include Crysterm

# `Mixin::TextEditing#cut` / `#paste`, the programmatic spellings of the
# `Ctrl-X` / `Ctrl-V` keys (an Edit menu's actions): the edit they make is
# reported as a keystroke's or `#insert_text`'s is — `Event::TextChanged`
# and `TextEdited`, the caret events — so a dirty flag or a caret readout
# bound to those events follows a menu edit as it follows typing.

private def editor(s, text = "hello world")
  te = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 3
  te.value = text
  s.repaint
  te
end

# The clipboard the widget copies to and pastes from (`#text_clipboard`).
private def clipboard_of(te)
  (te.window.application || Crysterm::Application.global).clipboard
end

describe "TextEditing#cut and #paste" do
  it "cut reports the text change and the dropped selection" do
    s = headless_screen(20, 3)
    te = editor s
    # "hello" selected the way a reported move selects it (`#text_cursor=`),
    # so its going is a change to report.
    c = TextCursor.new(te.document, 5)
    c.set_position(0, :keep_anchor)
    te.text_cursor = c
    te.selected_text.should eq "hello"
    changes = [] of String
    edits = 0
    selections = 0
    te.on(Event::TextChanged) { |e| changes << e.value }
    te.on(Event::TextEdited) { edits += 1 }
    te.on(Event::SelectionChanged) { selections += 1 }
    te.cut.should be_true
    te.value.should eq " world"
    changes.should eq [" world"]
    edits.should eq 1
    selections.should eq 1
    te.selection?.should be_false
    clipboard_of(te).text.should eq "hello"
    # Nothing selected: nothing cut, nothing reported.
    te.cut.should be_false
    changes.size.should eq 1
  end

  it "paste reports the text change and the caret move, and an empty clipboard nothing" do
    s = headless_screen(20, 3)
    te = editor s
    clipboard_of(te).text = "XY"
    te.cursor_pos = 5
    changes = [] of String
    edits = 0
    carets = [] of Int32
    te.on(Event::TextChanged) { |e| changes << e.value }
    te.on(Event::TextEdited) { edits += 1 }
    te.on(Event::CursorPositionChanged) { |e| carets << e.position }
    te.paste
    te.value.should eq "helloXY world"
    changes.should eq ["helloXY world"]
    edits.should eq 1
    carets.should eq [7]
    # A same-size replacement of a selection is a change too.
    te.cursor_pos = 0
    te.selection_anchor = 2
    carets.clear
    te.paste
    te.value.should eq "XYlloXY world"
    changes.last.should eq "XYlloXY world"
    carets.should eq [2]
    clipboard_of(te).text = ""
    te.paste
    changes.size.should eq 2
    carets.should eq [2]
  end

  it "cut and paste do nothing in a read-only widget" do
    s = headless_screen(20, 3)
    te = editor s
    te.cursor_pos = 0
    te.selection_anchor = 5
    te.read_only = true
    clipboard_of(te).text = "XY"
    changes = 0
    te.on(Event::TextChanged) { changes += 1 }
    te.cut.should be_false
    te.paste
    te.value.should eq "hello world"
    changes.should eq 0
  end
end
