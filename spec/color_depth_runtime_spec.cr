require "./spec_helper"

include Crysterm

# `colors.depth` (or the hyperlink policy) changed while a window runs: the
# next frame re-emits every cell at the new depth, not only the cells whose
# content changed.
describe "colors.depth changed at run time" do
  it "redraws the whole window at the new depth" do
    previous = Crysterm::Config.colors_depth
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::TrueColor
    output = IO::Memory.new
    window = Crysterm::Window.new input: IO::Memory.new, output: output, width: 20, height: 4
    box = Crysterm::Widget::Box.new parent: window, width: 20, height: 4, content: "colored"
    box.style.bg = 0x336699
    window.repaint
    window.color_count.should eq 0x1000000
    output.to_s.should contain "48;2;51;102;153" # the background as true color
    output.clear
    window.repaint
    output.to_s.should_not contain "48;2;51;102;153" # nothing changed: nothing re-emitted

    Crysterm::Config.colors_depth = Crysterm::ColorDepth::Ansi
    window.repaint
    window.color_count.should eq 16
    text = output.to_s
    text.should_not contain "48;2;"                                  # no true color at depth 16
    text.should match /\e\[[0-9;]*4[0-7][;m]|\e\[[0-9;]*10[0-7][;m]/ # a 16-color background re-emitted
    text.should contain "colored"

    output.clear
    window.hyperlinks = Crysterm::AutoToggle::On # a hyperlink policy change re-emits too
    window.repaint
    output.to_s.should contain "colored"
    output.clear
    window.repaint
    output.to_s.should_not contain "colored"
  ensure
    Crysterm::Config.colors_depth = previous if previous
    window.try &.destroy
  end
end
