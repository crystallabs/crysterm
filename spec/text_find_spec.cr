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

  it "searches backward for the last match starting before from" do
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

  describe "empty matches" do
    it "selects nothing where the match is, the document end included" do
      doc = TextDocument.new("ab\ncd")
      c = doc.find(/x*/).not_nil!
      {c.selection_start, c.selection_end, c.selection?}.should eq({0, 0, false})
      c = doc.find(/x*/, from: doc.size).not_nil!
      {c.selection_start, c.selection_end}.should eq({5, 5})
    end

    it "finds nothing forward from past the end, so a walk stepping past a match at the end stops" do
      doc = TextDocument.new("ab\ncd")
      doc.find(/x*/, from: doc.size + 1).should be_nil
      doc.find("d", from: doc.size + 1).should be_nil
      doc.find(/d/, from: doc.size).should be_nil
    end

    it "lets a forward walk that moves at least one position visit each match once" do
      doc = TextDocument.new("axb")
      seen = [] of {Int32, Int32}
      from = 0
      while c = doc.find(/x*/, from: from)
        seen << {c.selection_start, c.selection_end}
        from = Math.max(c.selection_end, c.selection_start + 1)
      end
      seen.should eq [{0, 0}, {1, 2}, {2, 2}, {3, 3}]
    end

    it "does not count an empty match at from backward, so a backward walk always moves" do
      doc = TextDocument.new("axx")
      seen = [] of {Int32, Int32}
      from = doc.size
      while c = doc.find(/x*/, from: from, flags: :backward)
        seen << {c.selection_start, c.selection_end}
        from = c.selection_start
      end
      seen.should eq [{1, 3}, {0, 0}]
    end

    it "finds nothing backward from the start" do
      doc = TextDocument.new("abc")
      doc.find(/x*/, from: 0, flags: :backward).should be_nil
      doc.find(/^/, from: 0, flags: :backward).should be_nil
      doc.find("a", from: 0, flags: :backward).should be_nil
    end
  end

  describe "block boundaries" do
    it "counts the block separator as one position" do
      doc = TextDocument.new("ab\ncd")
      c = doc.find(/b\nc/).not_nil!
      {c.selection_start, c.selection_end, c.selected_text}.should eq({1, 4, "b\nc"})
      c = doc.find(/b\n/, from: doc.size, flags: :backward).not_nil!
      {c.selection_start, c.selection_end}.should eq({1, 3})
    end

    it "starts a match at a block's end on the separator" do
      doc = TextDocument.new("ab\ncd")
      c = doc.find(/\n/).not_nil!
      {c.selection_start, c.selection_end}.should eq({2, 3})
      doc.find_block(c.selection_start).text.should eq "ab"
      c.block.text.should eq "cd"
    end

    it "finds the line anchors of a multiline regex at block starts and ends" do
      doc = TextDocument.new("ab\ncd")
      doc.find(/^/m, from: 1).not_nil!.selection_start.should eq 3
      doc.find(/$/m).not_nil!.selection_start.should eq 2
      doc.find(/^/m, from: doc.size, flags: :backward).not_nil!.selection_start.should eq 3
    end
  end
end
