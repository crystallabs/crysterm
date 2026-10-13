require "./spec_helper"

include Crysterm

# A document-backed editor hands `Event::TextChanged`/`TextEdited` the
# text as a proc (`Event::TextValue`): an edit whose listeners never read
# `value` does not rebuild the document's text, so an edit on a long
# document costs what the edit does, not what the document's size does.

describe Event::TextValue do
  it "builds no text for listeners that do not read it" do
    s = headless_screen(40, 10)
    pte = Widget::PlainTextEdit.new parent: s, width: 30, height: 5, content: "one\ntwo\nthree"
    s.repaint
    count = 0
    pte.on(Event::TextChanged) { count += 1 }
    pte.on(Event::TextEdited) { count += 1 }
    pte.apply_external_edit { pte.buf_delete(4, 8) }
    count.should eq 2
    pte.document.@plain_cache.should be_nil
    pte.cursor_pos = 0
    pte.insert_text "x"
    count.should eq 4
    pte.document.@plain_cache.should be_nil
  end

  it "builds the text once for both events when read" do
    s = headless_screen(40, 10)
    pte = Widget::PlainTextEdit.new parent: s, width: 30, height: 5, content: "one\ntwo"
    changed = edited = nil
    pte.on(Event::TextChanged) { |e| changed = e.value }
    pte.on(Event::TextEdited) { |e| edited = e.value }
    pte.apply_external_edit { pte.buf_insert(3, "!") }
    changed.should eq "one!\ntwo"
    edited.should be changed
  end

  it "still takes the text itself" do
    Event::TextChanged.new("abc").value.should eq "abc"
    Event::TextEdited.new(-> { "lazy" }).value.should eq "lazy"
  end
end
