require "./spec_helper"

include Crysterm

# Editing-surface edge cases: vertical caret motion over grapheme clusters,
# `PlainTextEdit`'s line patch against a display whose lines are not the
# document's blocks, the keystroke handler's change reporting, `LineEdit`'s
# history keys on a read-only field, `TextBrowser`'s link focus across a
# content replacement, and `TocView`'s document subscription.

describe "vertical caret motion over grapheme clusters" do
  it "lands at a cluster's start rather than between a base character and its combining mark" do
    s = headless_screen(40, 10)
    s.full_unicode = true
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 30, height: 5,
      content: "abcd\ne\u0301xyz"
    s.repaint
    pte.cursor_pos = 1
    pte._listener kp(key: ::Tput::Key::Down)
    # Line 2 starts at 5 with the two-codepoint cluster `e` + U+0301.
    pte.cursor_pos.should eq 5
  end

  it "keeps the goal column on a row of single-codepoint clusters" do
    s = headless_screen(40, 10)
    s.full_unicode = true
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 30, height: 5,
      content: "abcd\n漢字xyz"
    s.repaint
    pte.cursor_pos = 1
    pte._listener kp(key: ::Tput::Key::Down)
    pte.cursor_pos.should eq 6
  end
end

describe "Widget::PlainTextEdit display patch with a carriage return inside a block" do
  it "lays an edit of a later block out as a fresh editor over the same text does" do
    s = headless_screen(60, 20)
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 24, height: 6,
      content: "a\rb\nc"
    s.repaint
    pte.cursor_pos = pte.document.size
    pte.insert_text "X"
    s.repaint

    s2 = headless_screen(60, 20)
    ref = Widget::PlainTextEdit.new parent: s2, left: 0, top: 0, width: 24, height: 6,
      content: pte.value
    s2.repaint

    pte.wrapped_lines.lines.should eq ref.wrapped_lines.lines
    pte.wrapped_lines.fake.should eq ref.wrapped_lines.fake
  end
end

describe "text-editing keystroke change reporting" do
  it "reports a same-size replacement typed over a selection" do
    s = headless_screen(40, 6)
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 30, height: 4, content: "abc"
    s.repaint
    changes = [] of String
    pte.on(Crysterm::Event::TextChanged) { |e| changes << e.value }
    pte.selection_anchor = 0
    pte.cursor_pos = 1
    pte._listener kp('x')
    changes.should eq ["xbc"]
    pte.value.should eq "xbc"
  end

  it "reports nothing for a movement key extending a selection" do
    s = headless_screen(40, 6)
    pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 30, height: 4, content: "abc"
    s.repaint
    changes = [] of String
    pte.on(Crysterm::Event::TextChanged) { |e| changes << e.value }
    pte.selection_anchor = 0
    pte.cursor_pos = 2
    pte._listener kp(key: ::Tput::Key::ShiftRight)
    changes.should be_empty
    pte.selection_range.should eq(0...3)
    pte.value.should eq "abc"
  end
end

describe "Widget::LineEdit history keys on a read-only field" do
  it "leaves the text as it is" do
    s = headless_screen(40, 5)
    le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1,
      content: "shown", read_only: true, input_on_focus: false
    s.repaint
    le.history << "older"
    le._listener kp(key: ::Tput::Key::Up)
    le.value.should eq "shown"
    le._listener kp(key: ::Tput::Key::Down)
    le.value.should eq "shown"
  end

  it "still recalls an entry on an editable field" do
    s = headless_screen(40, 5)
    le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 20, height: 1,
      content: "draft", input_on_focus: false
    s.repaint
    le.history << "older"
    le._listener kp(key: ::Tput::Key::Up)
    le.value.should eq "older"
    le._listener kp(key: ::Tput::Key::Down)
    le.value.should eq "draft"
  end
end

describe "Widget::TextBrowser link focus across a content replacement" do
  it "is dropped with the links it pointed into" do
    s = headless_screen(40, 8)
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 8
    tb.set_markdown "go [one](u://1) and [two](u://2)"
    s.repaint
    tb.focus_link(1).should be_true
    tb.focus_link(1).should be_true
    tb.focused_link.should eq 1
    tb.extra_selections.size.should eq 1

    tb.set_markdown "see [three](u://3) and [four](u://4)"
    tb.focused_link.should eq -1
    tb.extra_selections.should be_empty

    clicked = [] of String
    tb.on(Crysterm::Event::AnchorClick) { |e| clicked << e.url }
    tb._listener kp(key: ::Tput::Key::Enter)
    clicked.should be_empty
  end
end

describe "Widget::TocView document subscription" do
  it "ends when the view is destroyed" do
    s = headless_screen 40, 20
    doc = TextDocument.from_markdown("# One")
    tv = Widget::TocView.new(parent: s, width: 24, height: 20, document: doc)
    tv.nodes.size.should eq 1
    tv.destroy
    left = tv.nodes.size
    doc.set_markdown "# One\n\n# Two\n\n# Three"
    tv.nodes.size.should eq left
  end
end
