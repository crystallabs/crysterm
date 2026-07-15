require "./spec_helper"

include Crysterm

# BUGS12 text-framework findings #2, #3, #4.

describe "BUGS12 text framework" do
  # Finding #2 — `<br>` inside `<li>` must not import as an extra list item.
  describe "TextHtml <br> inside <li>" do
    it "keeps one list item with a line break, not two" do
      blocks = Crysterm::TextHtml.parse("<ol><li>one<br>two</li></ol>")
      # Exactly one block carries the list identity (the item proper); the
      # post-break continuation block must not become a second list member.
      list_members = blocks.count { |b| !b.block_format.list_format.nil? }
      list_members.should eq 1
      # The break still splits the text into two blocks.
      blocks.map(&.text).should eq ["one", "two"]
    end
  end

  # Finding #3 — `replace_content` must emit ContentsChanged with the correct
  # `chars_added` (the new size), not a stale cached value.
  describe "TextDocument#set_plain_text ContentsChanged" do
    it "reports chars_added as the new size" do
      doc = TextDocument.new("a\nb\nc") # old size 5
      changes = [] of {Int32, Int32, Int32}
      doc.on(Event::ContentsChanged) { |e| changes << {e.position, e.chars_removed, e.chars_added} }
      doc.set_plain_text("hello") # new size 5
      changes.should eq [{0, 5, 5}]
    end
  end

  # Finding #4 — case-insensitive find must return correct positions even when
  # a character's Unicode downcase changes string length.
  describe "TextDocument#find with length-changing downcase" do
    # 'İ' (U+0130) is the trigger: `String#downcase` expands it to two
    # codepoints (i + combining dot), which used to shift every folded index
    # after it and desync returned positions from document positions.
    it "returns document-aligned positions for a match after İ" do
      doc = TextDocument.new("İstanbul is here")
      # "here" starts at document position 12; the old full-downcase path
      # returned 13 (shifted by the extra combining dot). Length-preserving
      # per-char folding keeps it aligned.
      c = doc.find("here").not_nil!
      c.selection_start.should eq 12
      c.selection_end.should eq 16
      c.selected_text.should eq "here"
    end

    it "selects the standalone \"is\" word at 9..11 (recipe case)" do
      doc = TextDocument.new("İstanbul is here")
      # Case-insensitively, "İstanbul" folds to "istanbul" and contains "is"
      # at position 0, so a plain find lands there; the recipe's intended
      # standalone "is" needs WholeWords, which also exercises the aligned
      # word-boundary probe (the buggy path returned nil here).
      c = doc.find("is", flags: :whole_words).not_nil!
      c.selection_start.should eq 9
      c.selection_end.should eq 11
      c.selected_text.should eq "is"
    end
  end
end
