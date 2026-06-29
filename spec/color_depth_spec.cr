require "./spec_helper"

include Crysterm

# Specs for output color-depth resolution: the `colors.depth` config option and
# the `screen.color_force` policy (resolved from the NO_COLOR / FORCE_COLOR /
# CLICOLOR[_FORCE] environment conventions via `Crysterm.color_force_from_env`),
# plus the monochrome guard in `Colors.sgr_color_to` that emits the terminal's
# default rather than a palette color once the depth collapses below 2.
describe "output color-depth resolution" do
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

  # `resolve_color_depth` maps the `screen.color_force` policy (+ `colors.depth`)
  # to a concrete count. Drive the option directly; snapshot/restore both options
  # around each example.
  describe "Screen.resolve_color_depth" do
    saved_force = Crysterm::ColorForce::None
    prev_depth = Crysterm::ColorDepth::Auto

    before_each do
      saved_force = Crysterm::Config.screen_color_force
      prev_depth = Crysterm::Config.colors_depth
      Crysterm::Config.screen_color_force = Crysterm::ColorForce::None
      Crysterm::Config.colors_depth = Crysterm::ColorDepth::Auto
    end

    after_each do
      Crysterm::Config.screen_color_force = saved_force
      Crysterm::Config.colors_depth = prev_depth
    end

    it "returns the detected count when policy is None and depth is auto" do
      Screen.resolve_color_depth(256).should eq 256
      Screen.resolve_color_depth(0x1000000).should eq 0x1000000
    end

    it "forces monochrome for ColorForce::Mono" do
      Crysterm::Config.screen_color_force = Crysterm::ColorForce::Mono
      Screen.resolve_color_depth(0x1000000).should eq 1
    end

    it "forces at least 16 / 256 colors, never lowering the detected depth" do
      Crysterm::Config.screen_color_force = Crysterm::ColorForce::Min16
      Screen.resolve_color_depth(8).should eq 16
      Screen.resolve_color_depth(0x1000000).should eq 0x1000000
      Crysterm::Config.screen_color_force = Crysterm::ColorForce::Min256
      Screen.resolve_color_depth(8).should eq 256
    end

    it "forces truecolor for ColorForce::Truecolor" do
      Crysterm::Config.screen_color_force = Crysterm::ColorForce::Truecolor
      Screen.resolve_color_depth(16).should eq 0x1000000
    end

    it "lets an explicit colors.depth override the force policy" do
      Crysterm::Config.screen_color_force = Crysterm::ColorForce::Mono
      Crysterm::Config.colors_depth = Crysterm::ColorDepth::TrueColor
      Screen.resolve_color_depth(16).should eq 0x1000000
    end

    it "applies colors.depth=none as monochrome" do
      Crysterm::Config.colors_depth = Crysterm::ColorDepth::None
      Screen.resolve_color_depth(0x1000000).should eq 1
    end
  end

  # The env precedence that seeds the option default: NO_COLOR, then CLICOLOR=0,
  # then FORCE_COLOR's level, then a non-zero CLICOLOR_FORCE.
  describe "Crysterm.color_force_from_env" do
    vars = %w[NO_COLOR CLICOLOR FORCE_COLOR CLICOLOR_FORCE]
    saved = {} of String => String?

    before_each do
      saved = vars.to_h { |v| {v, ENV[v]?} }
      vars.each { |v| ENV.delete v }
    end

    after_each do
      vars.each { |v| (s = saved[v]) ? (ENV[v] = s) : ENV.delete(v) }
    end

    it "returns None when no convention var is set" do
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::None
    end

    it "honors NO_COLOR (present and non-empty) as Mono, ignoring empty" do
      ENV["NO_COLOR"] = "1"
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::Mono
      ENV["NO_COLOR"] = ""
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::None
    end

    it "honors CLICOLOR=0 as Mono" do
      ENV["CLICOLOR"] = "0"
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::Mono
    end

    it "maps FORCE_COLOR levels (0 off, 1 -> 16, 2 -> 256, 3 -> truecolor)" do
      ENV["FORCE_COLOR"] = "0"
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::Mono
      ENV["FORCE_COLOR"] = "1"
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::Min16
      ENV["FORCE_COLOR"] = "2"
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::Min256
      ENV["FORCE_COLOR"] = "3"
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::Truecolor
    end

    it "honors a non-zero CLICOLOR_FORCE by forcing at least 16" do
      ENV["CLICOLOR_FORCE"] = "1"
      Crysterm.color_force_from_env.should eq Crysterm::ColorForce::Min16
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
