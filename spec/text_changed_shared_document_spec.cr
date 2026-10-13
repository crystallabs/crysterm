require "./spec_helper"

include Crysterm

# Every view on a `TextDocument` tells of every change of its text with
# `Event::TextChanged`, as Qt's views do (`QWidgetTextControl` connects the
# document's `contentsChanged` to its `textChanged`): the view that edited
# once, from its edit, and every other view once, from the document's
# `ContentsChangeFinished`. `Event::TextEdited` stays the editing view's alone.

private class Tally
  getter changed = 0
  getter edited = 0
  getter values = [] of String

  def initialize(view : Widget)
    view.on(Event::TextChanged) { |e| @changed += 1; @values << e.value }
    view.on(Event::TextEdited) { @edited += 1 }
  end
end

private def views(kind, text = "hello")
  s = headless_screen(40, 10, default_quit_keys: true)
  doc = TextDocument.new text
  a = kind.new parent: s, top: 0, width: 40, height: 4, document: doc
  b = kind.new parent: s, top: 4, width: 40, height: 4, document: doc
  s.repaint
  {doc, a, b}
end

private def key(c : Char)
  Event::KeyPress.new c
end

private def key(k : Tput::Key)
  Event::KeyPress.new '\0', k
end

{% for kind in [Widget::PlainTextEdit, Widget::TextEdit] %}
  describe {{ kind }} do
    describe "TextChanged on a shared document" do
      it "comes once from each view for a keystroke in one" do
        doc, a, b = views {{ kind }}
        ta, tb = Tally.new(a), Tally.new(b)
        a.cursor_pos = 5
        a._listener key('!')
        {ta.changed, ta.edited}.should eq({1, 1})
        {tb.changed, tb.edited}.should eq({1, 0})
        tb.values.should eq ["hello!"]
        b._listener key('?')
        {ta.changed, ta.edited}.should eq({2, 1})
        {tb.changed, tb.edited}.should eq({2, 1})
        doc.to_plain_text.should eq "?hello!"
      end

      it "comes once from each view for a text set on the document" do
        doc, a, b = views {{ kind }}
        ta, tb = Tally.new(a), Tally.new(b)
        doc.set_plain_text "other"
        {ta.changed, ta.edited}.should eq({1, 0})
        {tb.changed, tb.edited}.should eq({1, 0})
        ta.values.should eq ["other"]
        tb.values.should eq ["other"]
      end

      it "comes once from each view for a cursor's edit" do
        doc, a, b = views {{ kind }}
        ta, tb = Tally.new(a), Tally.new(b)
        TextCursor.new(doc, 0).insert_text "oh "
        {ta.changed, tb.changed}.should eq({1, 1})
        {ta.edited, tb.edited}.should eq({0, 0})
      end

      it "comes once from each view for an undo in one" do
        _, a, b = views {{ kind }}
        a.cursor_pos = 5
        a._listener key('!')
        ta, tb = Tally.new(a), Tally.new(b)
        a._listener key(Tput::Key::CtrlZ)
        a.value.should eq "hello"
        {ta.changed, ta.edited}.should eq({1, 0})
        {tb.changed, tb.edited}.should eq({1, 0})
      end

      it "comes once from each view for an engine's edit in one" do
        _, a, b = views {{ kind }}
        ta, tb = Tally.new(a), Tally.new(b)
        a.apply_external_edit { a.buf_insert 0, "x" }
        {ta.changed, ta.edited}.should eq({1, 1})
        {tb.changed, tb.edited}.should eq({1, 0})
      end

      it "comes once from each view for a text set through one" do
        _, a, b = views {{ kind }}
        ta, tb = Tally.new(a), Tally.new(b)
        a.value = "set"
        # `value=` is Qt's `setPlainText`: `textChanged` in every view,
        # `textEdited` in none.
        {ta.changed, ta.edited}.should eq({1, 0})
        {tb.changed, tb.edited}.should eq({1, 0})
      end
    end
  end
{% end %}

describe Widget::TextEdit do
  it "tells of a cursor's edit block once in each view" do
    doc, a, b = views Widget::TextEdit
    ta, tb = Tally.new(a), Tally.new(b)
    cur = TextCursor.new(doc, 0)
    cur.edit do |c|
      c.insert_text "a"
      c.insert_text "b"
      c.set_position 7
      c.insert_text "c"
    end
    {ta.changed, tb.changed}.should eq({1, 1})
    tb.values.should eq ["abhelloc"]
  end

  it "tells no view of a format change" do
    doc, a, b = views Widget::TextEdit
    ta, tb = Tally.new(a), Tally.new(b)
    cur = TextCursor.new(doc, 0)
    cur.set_position 5, :keep_anchor
    cur.merge_char_format TextCharFormat.new(bold: true)
    {ta.changed, tb.changed}.should eq({0, 0})
  end

  it "tells of an auto-formatted list marker once in the view that typed it" do
    _, a, b = views Widget::TextEdit, ""
    a.auto_formatting = Widget::TextEdit::AutoFormatting::All
    a._listener key('-')
    ta, tb = Tally.new(a), Tally.new(b)
    a._listener key(' ')
    # The space typed, then the marker taken off: the typing view tells of
    # both from its edits (as without a second view), the other view of
    # each change of the text.
    ta.changed.should eq 2
    tb.changed.should eq 2
    tb.edited.should eq 0
  end

  it "tells of a cell typed in a table once in the typing view" do
    doc, a, b = views Widget::TextEdit, ""
    table = doc.cursor(0).insert_table(2, 2)
    a.cursor_pos = table.cell_position(0, 0, 0) || raise "no cell"
    ta, tb = Tally.new(a), Tally.new(b)
    steps = 0
    doc.on(Event::ContentsChanged) do |e|
      steps += 1 if e.kind.replace? || (e.kind.edit? && (e.chars_removed > 0 || e.chars_added > 0))
    end
    a._listener key('x')
    # The table's re-rendering takes many steps, each its own
    # `ContentsChanged`, in one edit block: each view tells of the
    # keystroke once, the typing view from its edit, the other at the
    # block's end (`ContentsChangeFinished`), as Qt's `contentsChanged`.
    steps.should be > 1
    ta.changed.should eq 1
    ta.edited.should eq 1
    tb.changed.should eq 1
    tb.edited.should eq 0
  end
end
