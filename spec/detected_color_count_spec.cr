require "./spec_helper"

describe "Screen#detected_color_count" do
  it "answers what the Auto depth resolves to, whatever colors.depth is" do
    s = headless_screen(20, 5)
    dev = s.screen
    prev = Crysterm::Config.colors_depth
    begin
      Crysterm::Config.colors_depth = Crysterm::ColorDepth::Auto
      auto = dev.color_count
      dev.detected_color_count.should eq auto
      Crysterm::Config.colors_depth = (auto == 16 ? Crysterm::ColorDepth::Xterm256 : Crysterm::ColorDepth::Ansi)
      dev.color_count.should_not eq auto
      dev.detected_color_count.should eq auto
      s.detected_color_count.should eq auto # the window delegates it
    ensure
      Crysterm::Config.colors_depth = prev
    end
  end
end
