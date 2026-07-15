require "./spec_helper"

# Behavior lock for the two remaining pure `Crysterm::Helpers` methods without
# coverage: `drop_unicode` (astral-plane scrubber) and `hsort` (sort by
# descending `.render_index`). Both are instance methods, so mix the module into a host.
private class HelpersHost
  include Crysterm::Helpers
end

private record Indexed, render_index : Int32

describe Crysterm::Helpers do
  host = HelpersHost.new

  describe "#drop_unicode" do
    it "returns empty for nil or empty input" do
      host.drop_unicode(nil).should eq ""
      host.drop_unicode("").should eq ""
    end

    it "leaves BMP text (<= U+FFFF) untouched" do
      host.drop_unicode("hello").should eq "hello"
      host.drop_unicode("café €").should eq "café €" # é (U+00E9), € (U+20AC)
    end

    it "replaces each astral-plane (> U+FFFF) char with \"??\"" do
      # U+1F600 GRINNING FACE is a single astral codepoint.
      host.drop_unicode("a\u{1F600}b").should eq "a??b"
      host.drop_unicode("\u{1F600}\u{1F601}").should eq "????"
    end
  end

  describe "#hsort" do
    it "sorts by descending render_index in place" do
      arr = [Indexed.new(1), Indexed.new(3), Indexed.new(2)]
      host.hsort(arr)
      arr.map(&.render_index).should eq [3, 2, 1]
    end

    it "returns the same (mutated) array" do
      arr = [Indexed.new(5), Indexed.new(9)]
      host.hsort(arr).should be arr
      arr.map(&.render_index).should eq [9, 5]
    end
  end
end
