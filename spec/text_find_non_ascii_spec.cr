require "./spec_helper"

include Crysterm

# `TextDocument#find` walks its candidates by byte offset; on a text with
# non-ASCII the positions it gives are still the document's (char) ones.
describe "Crysterm::TextDocument#find on non-ASCII text" do
  it "finds forward and backward, whole words and case folded, at char positions" do
    doc = TextDocument.new("čaj čajnik ČAJ ž čaj")
    doc.find("čaj", from: 1, flags: :whole_words).not_nil!.selection_start.should eq 11
    doc.find("čaj", from: doc.size, flags: TextDocument::FindFlag::Backward | TextDocument::FindFlag::WholeWords).not_nil!.selection_start.should eq 17
    doc.find("čaj", from: 16, flags: TextDocument::FindFlag::Backward | TextDocument::FindFlag::WholeWords).not_nil!.selection_start.should eq 11
    doc.find("čaj", from: 14, flags: :backward).not_nil!.selection_start.should eq 11
    doc.find("čaj", from: 13, flags: :backward).not_nil!.selection_start.should eq 11
    doc.find("čaj", from: 12, flags: :backward).not_nil!.selection_start.should eq 11
    doc.find("čaj", from: 11, flags: :backward).not_nil!.selection_start.should eq 4
    doc.find("čaj", from: 2, flags: :backward).not_nil!.selection_start.should eq 0
    doc.find("čaj", from: 0, flags: :backward).should be_nil
    c = doc.find("ČAJ", from: 1, flags: :case_sensitive).not_nil!
    c.selection_start.should eq 11
    c.selected_text.should eq "ČAJ"
  end

  it "finds a Regex forward and backward at char positions" do
    doc = TextDocument.new("žž ab žž abab ž")
    c = doc.find(/(ab)+/, from: 4).not_nil!
    {c.selection_start, c.selection_end}.should eq({9, 13})
    c = doc.find(/(ab)+/, from: 12, flags: :backward).not_nil!
    {c.selection_start, c.selection_end}.should eq({9, 13})
    doc.find(/ž+/, from: doc.size, flags: TextDocument::FindFlag::Backward | TextDocument::FindFlag::WholeWords).not_nil!.selection_start.should eq 14
    doc.find(/x*/, from: 3).not_nil!.selection_start.should eq 3
    doc.find(/$/, from: 15, flags: :backward).should be_nil
  end
end
