require "./spec_helper"

# Behavior lock for `Crysterm::Helpers.replace_astral` (astral-plane
# scrubber). Class method — no host mixin needed.
describe Crysterm::Helpers do
  describe ".replace_astral" do
    it "returns empty for empty input" do
      Crysterm::Helpers.replace_astral("").should eq ""
    end

    it "leaves BMP text (<= U+FFFF) untouched" do
      Crysterm::Helpers.replace_astral("hello").should eq "hello"
      Crysterm::Helpers.replace_astral("café €").should eq "café €" # é (U+00E9), € (U+20AC)
    end

    it "replaces each astral-plane (> U+FFFF) char with \"??\"" do
      # U+1F600 GRINNING FACE is a single astral codepoint.
      Crysterm::Helpers.replace_astral("a\u{1F600}b").should eq "a??b"
      Crysterm::Helpers.replace_astral("\u{1F600}\u{1F601}").should eq "????"
    end

    it "is typed non-nilable: a nilable caller must .try it" do
      text : String? = nil
      text.try { |t| Crysterm::Helpers.replace_astral(t) }.should be_nil
    end
  end
end
