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
      # Emoji_Presentation=Yes codepoints outside the main emoji blocks —
      # previously measured as 1, misaligning layouts using them.
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

  # `width(String::Grapheme)` reads the stdlib-internal `@cluster` ivar
  # (`Char | String`) to skip the `String` allocation `grapheme.to_s` incurs
  # for the common Char-backed cluster. These pin the equivalence with the old
  # `width(grapheme.to_s)` path across every cluster shape, and — by exercising
  # both `@cluster` variants — pin the `Char | String` layout it depends on.
  describe ".width(String::Grapheme) via @cluster (equivalence with to_s path)" do
    it "matches width(grapheme.to_s) for every cluster category" do
      samples = [
        "a", "Z", " ", "~",             # ASCII (Char)
        "中", "日", "한", "Ａ",             # CJK / fullwidth, wide (Char)
        "ｶ",                            # halfwidth katakana, narrow (Char)
        "é",                            # precomposed accent (Char)
        "e\u{0301}",                    # combining sequence (String)
        "\u{0301}",                     # lone combining mark (Char)
        "👍", "🚀", "🟠", "⭐",             # emoji, wide (Char)
        "✌\u{FE0F}",                    # VS16 promotion (String)
        "👨\u{200D}👩\u{200D}👧\u{200D}👦", # ZWJ family (String)
        "🇯🇵", "🇺🇸",                     # regional-indicator flags (String)
        "\u{1F1EF}",                    # lone regional indicator (Char)
        "x\u{0301}\u{0302}",            # multi-combining cluster (String)
      ]
      samples.each do |s|
        s.each_grapheme do |g|
          Crysterm::Unicode.width(g).should eq Crysterm::Unicode.width(g.to_s)
        end
      end
    end

    it "exercises both @cluster variants (pins the Char | String layout)" do
      seen = Set(String).new
      "a中é\u{0301}👍🇯🇵".each_grapheme { |g| seen << g.@cluster.class.name }
      # Both a single-codepoint (Char) and a multi-codepoint (String) cluster
      # must be present, or the `@cluster` case would not be fully exercised.
      seen.should contain "Char"
      seen.should contain "String"
    end

    it "measures a lone regional indicator (a Char cluster) as width 2" do
      "\u{1F1EF}".each_grapheme do |g|
        g.@cluster.should be_a Char
        Crysterm::Unicode.width(g).should eq 2
      end
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
