require "./spec_helper"

include Crysterm

# API4 Area 5/6 mechanical text/reactive/input additions:
#
# - Reactive.computed/.signal factories (A4-46/A4-47)
# - SignalBase#on_change (A4-48)
# - TextCursor#insert_html/#insert_markdown, #column_number (A4-50/A4-51)
# - ObservableList#delete (A4-53)
# - TextList#remove_item (A4-54)
# - ComboBox#current_index=/#current_text= return values, #add_items (A4-67/A4-68)

private def doc_and_cursor(text = "", pos = 0)
  doc = Crysterm::TextDocument.new(text)
  {doc, Crysterm::TextCursor.new(doc, pos)}
end

describe "Reactive.computed" do
  it "infers T from the block and stays reactive" do
    n = Crysterm::Reactive::Signal.new 3
    doubled = Crysterm::Reactive.computed { n.value * 2 }
    doubled.should be_a Crysterm::Reactive::Computed(Int32)
    doubled.value.should eq 6
    n.value = 5
    doubled.value.should eq 10
  end
end

describe "Reactive.signal" do
  it "builds a Signal(T) seeded with the given value" do
    s = Crysterm::Reactive.signal "hi"
    s.should be_a Crysterm::Reactive::Signal(String)
    s.value.should eq "hi"
    s.value = "bye"
    s.value.should eq "bye"
  end
end

describe "SignalBase#on_change" do
  it "fires on Signal value changes, exposing the new value via #value" do
    s = Crysterm::Reactive::Signal.new 1
    seen = [] of Int32
    s.on_change { seen << s.value }
    s.value = 2
    s.value = 2 # change-guarded: no-op, no fire
    s.value = 3
    seen.should eq [2, 3]
  end

  it "is inherited by Computed" do
    n = Crysterm::Reactive::Signal.new 1
    c = Crysterm::Reactive.computed { n.value * 10 }
    seen = [] of Int32
    c.on_change { seen << c.value }
    n.value = 2
    n.value = 3
    seen.should eq [20, 30]
  end
end

describe "TextCursor#insert_html/#insert_markdown" do
  it "inserts an HTML fragment with real char formatting at the cursor" do
    doc, c = doc_and_cursor("")
    c.insert_html "<b>bold</b>"
    doc.to_plain_text.should eq "bold"
    doc.typing_format_at(1).bold?.should be_true
  end

  it "inserts a Markdown fragment with real char formatting at the cursor" do
    doc, c = doc_and_cursor("")
    c.insert_markdown "**bold**"
    doc.to_plain_text.should eq "bold"
    doc.typing_format_at(1).bold?.should be_true
  end

  it "inserts html/markdown mid-document, at the cursor position" do
    doc, c = doc_and_cursor("[]", 1)
    c.insert_markdown "**x**"
    doc.to_plain_text.should eq "[x]"
    # typing_format_at(offset) is the format of the character *preceding*
    # offset (Qt cursor semantics) — 'x' is at index 1, so query offset 2.
    doc.typing_format_at(2).bold?.should be_true
    doc.typing_format_at(1).bold?.should be_false # '[' stays unformatted
  end
end

describe "TextCursor#column_number" do
  it "aliases #position_in_block" do
    _, c = doc_and_cursor("hello\nworld", 8)
    c.column_number.should eq c.position_in_block
    c.column_number.should eq 2
  end
end

describe "ObservableList#delete" do
  it "removes the first occurrence by value, returns it, and emits Remove at its index" do
    list = Crysterm::Reactive::ObservableList(String).new %w[a b c b]
    events = [] of {Crysterm::Reactive::ListOp, Int32, Int32}
    list.on(Crysterm::Event::ListChanged) { |e| events << {e.op, e.index, e.count} }

    list.delete("b").should eq "b"
    list.to_a.should eq %w[a c b]
    events.should eq [{Crysterm::Reactive::ListOp::Remove, 1, 1}]
  end

  it "returns nil and emits nothing when the item is absent" do
    list = Crysterm::Reactive::ObservableList(String).new %w[a b c]
    fired = false
    list.on(Crysterm::Event::ListChanged) { fired = true }

    list.delete("z").should be_nil
    list.to_a.should eq %w[a b c]
    fired.should be_false
  end
end

describe "TextList#remove_item" do
  it "removes the item at the given 0-based index" do
    doc, c = doc_and_cursor("one\ntwo\nthree")
    c.set_position(0)
    c.set_position(9, :keep_anchor) # spans all three blocks
    list = c.create_list(:disc)
    list.count.should eq 3

    list.remove_item(1) # "two"
    list.count.should eq 2
    list.member?(doc.blocks[1]).should be_false
    list.member?(doc.blocks[0]).should be_true
    list.member?(doc.blocks[2]).should be_true
  end

  it "is a no-op for an out-of-range index" do
    doc, c = doc_and_cursor("one\ntwo")
    c.set_position(0)
    c.set_position(doc.size, :keep_anchor)
    list = c.create_list(:disc)
    list.count.should eq 2

    list.remove_item(5)
    list.count.should eq 2
  end
end

describe "ComboBox setter return values" do
  it "current_index= returns the clamped index" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["A", "B", "C"]

    (cb.current_index = 1).should eq 1
    cb.current_index.should eq 1
    (cb.current_index = 99).should eq 2 # clamped to the last option
    cb.current_index.should eq 2
  end

  it "current_index= on an empty box returns the unchanged selected index" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: [] of String

    (cb.current_index = 3).should eq 0
  end

  it "current_text= returns the resulting current text" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["A", "B", "C"]

    (cb.current_text = "C").should eq "C"
    cb.current_text.should eq "C"
  end
end

describe "ComboBox#add_items" do
  it "bulk-appends, emitting exactly one CurrentChanged for the whole batch" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: [] of String

    count = 0
    cb.on(Crysterm::Event::CurrentChanged) { count += 1 }
    cb.add_items(["a", "b", "c"])

    cb.count.should eq 3
    cb.current_index.should eq 0
    cb.current_text.should eq "a"
    count.should eq 1
  end

  it "does not emit CurrentChanged when appending to a non-empty box (selection unmoved)" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["a"]

    count = 0
    cb.on(Crysterm::Event::CurrentChanged) { count += 1 }
    cb.add_items(["b", "c"])

    cb.count.should eq 3
    cb.current_index.should eq 0
    count.should eq 0
  end

  it "is a no-op for an empty batch" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, top: 0, left: 0, width: 12, height: 1,
      options: ["a"]

    cb.add_items([] of String)
    cb.count.should eq 1
  end
end
