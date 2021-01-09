require "./spec_helper"

class X
  include Crysterm::Helpers
end

x = X.new

describe Crysterm do
  describe "escape" do
    it "wraps/escapes { and }" do
      x.escape("my").should eq "my"
      x.escape("my {").should eq "my {open}"
      x.escape("{ { term }").should eq "{open} {open} term {close}"
    end
  end

  describe "generate_tags" do
    it "returns named tuple when invoked without text" do
      x.generate_tags({"fg" => "lightblack"}).should eq({
        open:  "{light-black-fg}",
        close: "{/light-black-fg}",
      })
    end

    it "returns text wrapped when invoked with text" do
      x.generate_tags({"fg" => "lightblack"}, " text ").should eq \
        "{light-black-fg} text {/light-black-fg}"
    end
  end

  describe "strip_tags" do
    # Strips text of tags and SGR sequences.
    #
    # ```
    # .gsub(/\{(\/?)([\w\-,;!#]*)\}/, "").gsub(/\x1b\[[\d;]*m/, "")
    # ```
    it "leaves plain strings as-is" do
      x.strip_tags("my").should eq "my"
    end

    it "strips {...} tags" do
      x.strip_tags("1{tag}text{/tag}2").should eq "1text2"
    end

    it "strips a mix of {...} tags and ESC[...m (SGR) sequences" do
      x.strip_tags("1\e[1;2m{tag}text\e[0m{/tag}2").should eq "1text2"
    end
  end

  describe "clean_tags" do
    it "strips tags, then removes any leading/trailing whitespace" do
      x.clean_tags("   1\e[1;2m{tag}text\e[0m{/tag}2  ").should eq "1text2"
    end
  end
end
