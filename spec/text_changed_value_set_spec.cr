require "./spec_helper"

include Crysterm

# A text set through a view (`value=`, `text=`, `PlainTextEdit#plain_text=`) emits
# `Event::TextChanged` in that view, as Qt's `setPlainText` emits
# `textChanged`, and never `Event::TextEdited`, which is the user's. A
# document-backed view emits it for every set, the document being reset even
# to the text it had (Qt's `QPlainTextEdit::setPlainText`); a `LineEdit`
# only for a different text (Qt's `QLineEdit::setText`).

private class Tally
  getter changed = 0
  getter edited = 0
  getter values = [] of String

  def initialize(view : Widget)
    view.on(Event::TextChanged) { |e| @changed += 1; @values << e.value }
    view.on(Event::TextEdited) { @edited += 1 }
  end
end

{% for kind in [Widget::PlainTextEdit, Widget::TextEdit] %}
  describe {{ kind }} do
    describe "TextChanged for a text set through the view" do
      it "comes once for value=, with the new text, and no TextEdited" do
        s = headless_screen(40, 10)
        v = {{ kind }}.new parent: s, width: 40, height: 4, content: "hello"
        t = Tally.new v
        v.value = "other"
        {t.changed, t.edited}.should eq({1, 0})
        t.values.should eq ["other"]
        v.cursor_position.should eq 5
      end

      it "comes once for text=" do
        s = headless_screen(40, 10)
        v = {{ kind }}.new parent: s, width: 40, height: 4
        t = Tally.new v
        v.text = "abc"
        {t.changed, t.edited}.should eq({1, 0})
      end

      it "comes for the text it had, the document being reset" do
        s = headless_screen(40, 10)
        v = {{ kind }}.new parent: s, width: 40, height: 4, content: "same"
        t = Tally.new v
        v.value = "same"
        t.changed.should eq 1
      end
    end
  end
{% end %}

describe Widget::LineEdit do
  it "tells of a text set through value= only when it differs, without TextEdited" do
    s = headless_screen(40, 10)
    le = Widget::LineEdit.new parent: s, width: 20, height: 1, content: "abc"
    t = Tally.new le
    le.value = "xyz"
    {t.changed, t.edited}.should eq({1, 0})
    le.value = "xyz"
    t.changed.should eq 1
  end
end
