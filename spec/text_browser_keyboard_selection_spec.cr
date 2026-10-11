require "./spec_helper"

include Crysterm

# Keyboard selection in a read-only viewer: `Shift` + a movement key extends
# the selection from the caret in a `Widget::TextBrowser` as it does in an
# editor (Qt's `QTextCursor::KeepAnchor` moves, under
# `TextSelectableByKeyboard`), paging included, and the read-only
# navigation keys keep their meaning. Keystrokes go straight through
# `#_listener`, as `_read_input` wires them.

private def ctl(k : ::Tput::Key)
  kp key: k
end

private def new_browser(s, height = 6)
  doc = TextDocument.from_markdown((1..40).map { |i| "para #{i}" }.join("\n\n"))
  tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: height, document: doc
  tb.cursor_pos = 0 # a document handed over parks the caret at its end
  s.repaint
  tb
end

describe "Widget::TextBrowser keyboard selection" do
  it "extends the selection with Shift + arrows, Home and End, and drops it on a plain move" do
    s = headless_screen(80, 24)
    tb = new_browser s
    tb.read_only?.should be_true
    tb._listener ctl(::Tput::Key::ShiftRight)
    tb.selected_text.should eq "p"
    tb._listener ctl(::Tput::Key::ShiftEnd)
    tb.selected_text.should eq "para 1"
    tb._listener ctl(::Tput::Key::ShiftDown)
    tb.selected_text.should eq "para 1\npara 2"
    tb._listener ctl(::Tput::Key::ShiftHome)
    tb.selected_text.should eq "para 1\n"
    tb._listener ctl(::Tput::Key::ShiftUp)
    tb.selection?.should be_false
    tb._listener ctl(::Tput::Key::ShiftRight)
    tb._listener ctl(::Tput::Key::ShiftLeft)
    tb.selection?.should be_false
    tb._listener ctl(::Tput::Key::ShiftRight)
    tb._listener ctl(::Tput::Key::Right)
    tb.selection?.should be_false
    tb.cursor_pos.should eq 1
  end

  it "selects a page with Shift + PageDown and back with Shift + PageUp" do
    s = headless_screen(80, 24)
    tb = new_browser s
    tb._listener ctl(::Tput::Key::ShiftPageDown)
    selected = tb.selected_text
    selected.should start_with "para 1\npara 2\n"
    selected.lines.size.should be > 2
    tb._listener ctl(::Tput::Key::ShiftPageUp)
    tb.selection?.should be_false
  end

  it "keeps the read-only navigation keys: Space pages without selecting" do
    s = headless_screen(80, 24)
    tb = new_browser s
    tb._listener kp(' ')
    tb.selection?.should be_false
    tb.cursor_pos.should be > 0
  end
end
