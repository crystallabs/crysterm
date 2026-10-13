require "./spec_helper"

include Crysterm

# Backward, `TextDocument#find` takes the last match starting before `from`,
# as Qt's `QTextDocument::find(…, FindBackward)` (`lastIndexOf` from the
# position before the cursor) and Vim's `?` do: a match the position is
# inside is found, from its start, not skipped for the one before it.
describe "Crysterm::TextDocument#find backward" do
  it "finds a string match the position is inside" do
    doc = TextDocument.new("foo bar foo")
    c = doc.find("foo", from: 10, flags: :backward).not_nil!
    {c.selection_start, c.selection_end}.should eq({8, 11})
    doc.find("foo", from: 9, flags: :backward).not_nil!.selection_start.should eq 8
  end

  it "finds a regex match the position is inside, whole, past the position" do
    doc = TextDocument.new("a1 b22 c333")
    c = doc.find(/\d+/, from: 9, flags: :backward).not_nil!
    {c.selection_start, c.selected_text}.should eq({8, "333"})
  end

  it "does not find a match starting at the position, so stepping back from a match's start moves" do
    doc = TextDocument.new("foo foo foo")
    starts = [] of Int32
    from = doc.size
    while c = doc.find("foo", from: from, flags: :backward)
      starts << c.selection_start
      from = c.selection_start
    end
    starts.should eq [8, 4, 0]
    starts.clear
    from = doc.size
    while c = doc.find(/fo+/, from: from, flags: :backward)
      starts << c.selection_start
      from = c.selection_start
    end
    starts.should eq [8, 4, 0]
  end

  it "reads anchors and whole words against the whole document, not the text before the position" do
    doc = TextDocument.new("catalog\ncat")
    doc.find(/cat\b/, from: 2, flags: :backward).should be_nil
    doc.find(/cat\z/, from: 10, flags: :backward).not_nil!.selection_start.should eq 8
    doc.find("cat", from: 2, flags: TextDocument::FindFlag::Backward | TextDocument::FindFlag::WholeWords).should be_nil
    doc.find("cat", from: 10, flags: TextDocument::FindFlag::Backward | TextDocument::FindFlag::WholeWords).not_nil!.selection_start.should eq 8
  end
end
