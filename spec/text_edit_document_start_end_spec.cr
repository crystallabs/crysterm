require "./spec_helper"

include Crysterm

private TEXT = (1..50).map { |i| "line #{i.to_s.rjust(2, '0')}" }.join("\n")

private def press(te, key : Tput::Key)
  te._listener Crysterm::Event::KeyPress.new('\0', key)
end

# Ctrl+Home/Ctrl+End go to the start/end of the whole text, as Qt's text
# edits bind `QKeySequence::MoveToStartOfDocument`/`MoveToEndOfDocument`;
# Home/End stay on the caret's line.
{% for klass in [Widget::PlainTextEdit, Widget::TextEdit, Widget::TextBrowser] %}
  describe "{{ klass }} Ctrl+Home/Ctrl+End" do
    it "moves the caret to the start and the end of the document, scrolling to it" do
      s = headless_screen(30, 10)
      te = {{ klass }}.new parent: s, left: 0, top: 0, width: 30, height: 10
      te.value = TEXT
      s.repaint
      te.cursor_pos = 20 * 8 + 3
      s.repaint

      press te, Tput::Key::CtrlEnd
      te.cursor_pos.should eq TEXT.size
      te.scroll_position.should be > 0

      press te, Tput::Key::CtrlHome
      te.cursor_pos.should eq 0
      te.scroll_position.should eq 0
    end

    it "accepts the key and drops a selection" do
      s = headless_screen(30, 10)
      te = {{ klass }}.new parent: s, left: 0, top: 0, width: 30, height: 10
      te.value = TEXT
      s.repaint
      te.cursor_pos = 16
      press te, Tput::Key::ShiftRight
      te.selection?.should be_true

      ev = Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlHome)
      te._listener ev
      ev.accepted?.should be_true
      te.selection?.should be_false
      te.cursor_pos.should eq 0
    end
  end
{% end %}

describe "Widget::LineEdit Ctrl+Home/Ctrl+End" do
  it "moves the caret to the start and the end of the field" do
    s = headless_screen(30, 3)
    le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 30, height: 1
    le.value = "hello world"
    le.cursor_pos = 5
    press le, Tput::Key::CtrlEnd
    le.cursor_pos.should eq 11
    press le, Tput::Key::CtrlHome
    le.cursor_pos.should eq 0
  end
end
