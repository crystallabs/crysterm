require "./spec_helper"

include Crysterm

describe "Crysterm::TextDocument#find" do
  it "finds forward, case-insensitively by default, returning a selection" do
    doc = TextDocument.new("Hello World")
    c = doc.find("world").not_nil!
    c.selection_start.should eq 6
    c.selection_end.should eq 11
    c.anchor.should eq 6
    c.selected_text.should eq "World"
  end

  it "starts at the given position" do
    doc = TextDocument.new("one two one")
    doc.find("one").not_nil!.selection_start.should eq 0
    doc.find("one", from: 1).not_nil!.selection_start.should eq 8
    doc.find("one", from: 9).should be_nil
  end

  it "honors CaseSensitive" do
    doc = TextDocument.new("Hello World")
    doc.find("world", flags: :case_sensitive).should be_nil
    doc.find("World", flags: :case_sensitive).should_not be_nil
  end

  it "honors WholeWords" do
    doc = TextDocument.new("cat catalog cat")
    c = doc.find("cat", from: 1, flags: :whole_words).not_nil!
    c.selection_start.should eq 12
  end

  it "searches backward for the last match ending at or before from" do
    doc = TextDocument.new("cat catalog cat")
    c = doc.find("cat", from: 11, flags: TextDocument::FindFlag::Backward | TextDocument::FindFlag::WholeWords).not_nil!
    c.selection_start.should eq 0
    doc.find("cat", from: doc.size, flags: :backward).not_nil!.selection_start.should eq 12
  end

  it "matches across block separators as newline" do
    doc = TextDocument.new("hello\nworld")
    c = doc.find("lo\nwo").not_nil!
    c.selection_start.should eq 3
    c.selected_text.should eq "lo\nwo"
  end

  it "finds regexes" do
    doc = TextDocument.new("Hello World")
    c = doc.find(/W\w+/).not_nil!
    c.selected_text.should eq "World"
    doc.find(/\d+/).should be_nil
  end

  it "finds regexes backward with flags" do
    doc = TextDocument.new("a1 b22 c333")
    c = doc.find(/\d+/, from: doc.size, flags: :backward).not_nil!
    c.selected_text.should eq "333"
    c = doc.find(/\d+/, from: 6, flags: :backward).not_nil!
    c.selected_text.should eq "22"
  end

  it "returns nil for an empty subject or no match" do
    doc = TextDocument.new("abc")
    doc.find("").should be_nil
    doc.find("zzz").should be_nil
  end
end
