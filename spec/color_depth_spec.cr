require "./spec_helper"

include Crysterm

# Specs for output color-depth resolution: the `colors.depth` config option and
# the NO_COLOR / FORCE_COLOR / CLICOLOR[_FORCE] environment conventions
# (`Screen.resolve_color_depth`), plus the monochrome guard in
# `Colors.sgr_color_to` that emits the terminal's default rather than a palette
# color once the depth collapses below 2.
describe "output color-depth resolution" do
  # Resolution reads process ENV and the global `colors.depth` option; snapshot
  # and restore both around each example so they don't leak into one another.
  color_env = %w[NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE]
  saved = Hash(String, String?).new
  prev_depth = Crysterm::ColorDepth::Auto

  before_each do
    color_env.each { |k| saved[k] = ENV[k]?; ENV.delete k }
    prev_depth = Crysterm::Config.colors_depth
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::Auto
  end

  after_each do
    color_env.each { |k| (v = saved[k]?) ? (ENV[k] = v) : ENV.delete(k) }
    Crysterm::Config.colors_depth = prev_depth
  end

  describe "Crysterm::ColorDepth#to_count" do
    it "maps each depth to its terminal color count (Auto has none)" do
      Crysterm::ColorDepth::Auto.to_count.should be_nil
      Crysterm::ColorDepth::None.to_count.should eq 1
      Crysterm::ColorDepth::Basic.to_count.should eq 8
      Crysterm::ColorDepth::Ansi.to_count.should eq 16
      Crysterm::ColorDepth::Xterm256.to_count.should eq 256
      Crysterm::ColorDepth::TrueColor.to_count.should eq 0x1000000
    end
  end

  describe "Screen.resolve_color_depth" do
    it "returns the detected count when depth is auto and no env is set" do
      Screen.resolve_color_depth(256).should eq 256
      Screen.resolve_color_depth(0x1000000).should eq 0x1000000
    end

    it "honors NO_COLOR (present and non-empty) as monochrome" do
      ENV["NO_COLOR"] = "1"
      Screen.resolve_color_depth(0x1000000).should eq 1
    end

    it "ignores an empty NO_COLOR (per no-color.org)" do
      ENV["NO_COLOR"] = ""
      Screen.resolve_color_depth(256).should eq 256
    end

    it "honors CLICOLOR=0 as monochrome" do
      ENV["CLICOLOR"] = "0"
      Screen.resolve_color_depth(256).should eq 1
    end

    it "honors CLICOLOR_FORCE (non-zero) by forcing color on" do
      ENV["CLICOLOR_FORCE"] = "1"
      Screen.resolve_color_depth(8).should eq 16 # at least 16
    end

    it "maps FORCE_COLOR levels (0 off, 1 -> 16, 2 -> 256, 3 -> truecolor)" do
      ENV["FORCE_COLOR"] = "0"
      Screen.resolve_color_depth(256).should eq 1
      ENV["FORCE_COLOR"] = "1"
      Screen.resolve_color_depth(8).should eq 16
      ENV["FORCE_COLOR"] = "2"
      Screen.resolve_color_depth(8).should eq 256
      ENV["FORCE_COLOR"] = "3"
      Screen.resolve_color_depth(16).should eq 0x1000000
    end

    it "never lowers the detected depth when forcing color on" do
      ENV["FORCE_COLOR"] = "1"
      Screen.resolve_color_depth(0x1000000).should eq 0x1000000 # max(detected, 16)
    end

    it "lets an explicit colors.depth override the environment" do
      ENV["NO_COLOR"] = "1"
      Crysterm::Config.colors_depth = Crysterm::ColorDepth::TrueColor
      Screen.resolve_color_depth(16).should eq 0x1000000
    end

    it "applies colors.depth=none as monochrome" do
      Crysterm::Config.colors_depth = Crysterm::ColorDepth::None
      Screen.resolve_color_depth(0x1000000).should eq 1
    end
  end

  describe "Colors.sgr_color_to monochrome guard" do
    it "emits the terminal default instead of a palette color when colors < 2" do
      String.build { |io| Colors.sgr_color_to(io, 0xff0000, true, 1) }.should eq "39"
      String.build { |io| Colors.sgr_color_to(io, 0x00ff00, false, 1) }.should eq "49"
    end

    it "still emits real colors at normal depths" do
      String.build { |io| Colors.sgr_color_to(io, 0xff8800, true, 0x1000000) }
        .should eq "38;2;255;136;0"
      String.build { |io| Colors.sgr_color_to(io, -1, true, 256) }.should eq "39"
    end
  end
end
