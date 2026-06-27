require "./spec_helper"

include Crysterm

# Phase-0 grapheme support: column-width measurement (`Crysterm::Unicode`).
describe Crysterm::Unicode do
  describe ".width (one grapheme cluster)" do
    it "is 1 for plain ASCII / narrow characters" do
      Crysterm::Unicode.width("a").should eq 1
      Crysterm::Unicode.width(" ").should eq 1
    end

    it "is 2 for East-Asian-Wide and Fullwidth characters" do
      Crysterm::Unicode.width("中").should eq 2
      Crysterm::Unicode.width("ｶ").should eq 1 # halfwidth katakana stays narrow
      Crysterm::Unicode.width("Ａ").should eq 2 # fullwidth A
      Crysterm::Unicode.width("한").should eq 2 # Hangul syllable
    end

    it "is 1 for a base + combining mark (a single cluster)" do
      Crysterm::Unicode.width("é").should eq 1 # 'e' + combining acute
      Crysterm::Unicode.width("é").should eq 1  # precomposed
    end

    it "is 0 for a lone combining mark" do
      Crysterm::Unicode.width("\u{0301}").should eq 0
    end

    it "is 2 for emoji" do
      Crysterm::Unicode.width("👍").should eq 2
      Crysterm::Unicode.width("🚀").should eq 2
    end

    it "is 2 for emoji in the WIDE-table gaps (colored shapes, large squares/star/circle)" do
      # Emoji_Presentation=Yes codepoints that sit outside the main emoji
      # blocks — previously measured as 1, misaligning any layout using them.
      Crysterm::Unicode.width("🟠").should eq 2 # U+1F7E0 large orange circle
      Crysterm::Unicode.width("🟢").should eq 2 # U+1F7E2 large green circle
      Crysterm::Unicode.width("🟥").should eq 2 # U+1F7E5 large red square
      Crysterm::Unicode.width("🟫").should eq 2 # U+1F7EB large brown square
      Crysterm::Unicode.width("🟰").should eq 2 # U+1F7F0 heavy equals sign
      Crysterm::Unicode.width("⬛").should eq 2 # U+2B1B black large square
      Crysterm::Unicode.width("⬜").should eq 2 # U+2B1C white large square
      Crysterm::Unicode.width("⭐").should eq 2 # U+2B50 white medium star
      Crysterm::Unicode.width("⭕").should eq 2 # U+2B55 heavy large circle
    end

    it "treats a ZWJ emoji sequence as one width-2 cluster" do
      Crysterm::Unicode.width("👨‍👩‍👧‍👦").should eq 2
    end

    it "treats a regional-indicator flag as one width-2 cluster" do
      Crysterm::Unicode.width("🇯🇵").should eq 2
    end

    it "promotes VS16 emoji presentation to width 2" do
      Crysterm::Unicode.width("✌\u{FE0F}").should eq 2
    end
  end

  describe ".display_width (whole string)" do
    it "sums grapheme-cluster widths" do
      Crysterm::Unicode.display_width("").should eq 0
      Crysterm::Unicode.display_width("hello").should eq 5
      Crysterm::Unicode.display_width("a中b").should eq 4 # 1 + 2 + 1
      Crysterm::Unicode.display_width("café").should eq 4
      Crysterm::Unicode.display_width("é").should eq 1    # one cluster
      Crysterm::Unicode.display_width("ab👍cd").should eq 6 # 1+1+2+1+1
    end

    it "counts a ZWJ family as a single width-2 cluster, not per codepoint" do
      Crysterm::Unicode.display_width("👨‍👩‍👧‍👦!").should eq 3
    end

    it "counts CJK text by columns" do
      Crysterm::Unicode.display_width("日本語").should eq 6
    end
  end
end
