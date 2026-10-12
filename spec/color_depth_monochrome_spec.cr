require "./spec_helper"

include Crysterm

# `colors.depth: none` (`ColorDepth::None`, `Screen#color_count == 1`): a
# monochrome terminal has no colors to send, so a cell's polarity against the
# terminal's own goes through reverse video (SGR 7) — a light theme on a dark
# terminal comes out black on white instead of in the terminal's defaults.
module MonoSpecHelpers
  extend self

  # Renders *boxes* (each `{fg, bg, reverse}`) side by side in a fresh window at
  # the monochrome depth and returns the frame's bytes. *light_terminal* probes
  # the terminal's default background as white.
  # Yields a fresh window at the monochrome depth and its output, the depth
  # put back afterwards; *light_terminal* probes the terminal's default
  # background as white.
  def mono_window(width : Int32, height : Int32, light_terminal = false, optimization = nil, &)
    previous = Crysterm::Config.colors_depth
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::None
    output = IO::Memory.new
    window = Crysterm::Window.new input: IO::Memory.new, output: output, error: IO::Memory.new, width: width, height: height
    window.optimization = optimization if optimization
    if light_terminal
      window.tput.features.default_background = Tput::RGB.new(255_u8, 255_u8, 255_u8)
    end
    yield window, output
  ensure
    Crysterm::Config.colors_depth = previous if previous
    window.try &.destroy
  end

  # Renders *boxes* (each `{fg, bg, reverse}`) side by side at the monochrome
  # depth and returns the frame's bytes.
  def mono_frame(boxes : Array({Int32, Int32, Bool}), light_terminal = false) : String
    mono_window(10 * boxes.size, 3, light_terminal) do |window, output|
      boxes.each_with_index do |(fg, bg, reverse), i|
        box = Crysterm::Widget::Box.new parent: window, left: 10 * i, top: 0, width: 10, height: 3, content: "box#{i}"
        box.style.fg = fg
        box.style.bg = bg
        box.style.reverse = reverse
      end
      window.repaint
      window.color_count.should eq 1
      output.to_s
    end
  end

  # Whether *text* carries any SGR color parameter (truecolor/256 `38;`/`48;`,
  # or a 3x/4x/9x/10x palette code).
  def colored?(text : String) : Bool
    text.scan(/\e\[([0-9;]*)m/).any? do |m|
      m[1].split(';').any? { |p| p.in?("38", "48") || p =~ /\A(3|4|9|10)[0-9]\z/ }
    end
  end
end

include MonoSpecHelpers

describe "ColorDepth::None" do
  it "renders a light cell on a dark terminal as reverse video and sends no color" do
    text = mono_frame [{0x000000, 0xffffff, false}]
    text.should contain "\e[7m"
    colored?(text).should be_false
    text.should contain "box0"
  end

  it "renders a dark cell on a dark terminal plain" do
    text = mono_frame [{0xffffff, 0x202020, false}]
    text.should_not contain "\e[7m"
    text.should_not contain "7;"
    colored?(text).should be_false
  end

  it "flips the other way on a terminal whose default background is light" do
    light = mono_frame [{0x000000, 0xffffff, false}], light_terminal: true
    light.should_not contain "\e[7m"
    light.should_not contain "7;"
    dark = mono_frame [{0xffffff, 0x202020, false}], light_terminal: true
    dark.should contain "\e[7m"
  end

  it "un-reverses a cell its style already reversed (XOR)" do
    text = mono_frame [{0x000000, 0xffffff, true}]
    text.should_not contain "\e[7m"
    text.should_not contain "7;"
  end

  it "leaves the foreground alone: a dark foreground on the default background does not flip" do
    mono_window(10, 3) do |window, output|
      box = Crysterm::Widget::Box.new parent: window, width: 10, height: 3, content: "dim"
      box.style.fg = 0x000000
      window.repaint
      output.to_s.should_not contain "\e[7m"
    end
  end

  it "writes no SGR between two differently colored cells of one polarity" do
    one = mono_frame [{0x000000, 0xffffff, false}, {0x000000, 0xffffff, false}]
    two = mono_frame [{0x000000, 0xffffff, false}, {0x000000, 0xeeeeee, false}]
    two.should eq one
    # One reverse per row, nothing between the boxes.
    two.scan(/\e\[7m/).size.should eq 3
  end

  describe "monochrome depth, the frame after a change" do
    it "re-emits the frame when the terminal's polarity becomes known" do
      mono_window(10, 2) do |window, output|
        box = Crysterm::Widget::Box.new parent: window, width: 10, height: 2, content: "light"
        box.style.fg = 0x000000
        box.style.bg = 0xffffff
        window.repaint
        output.to_s.should contain "\e[7m" # dark terminal assumed: reversed
        output.clear
        window.repaint
        output.to_s.should eq "" # nothing changed
        # The OSC 11 answer arrives: the terminal is light, so the same cells
        # must reach the wire again, plain this time.
        window.tput.features.default_background = Tput::RGB.new(255_u8, 255_u8, 255_u8)
        window.repaint
        text = output.to_s
        text.should contain "light"
        text.should_not contain "\e[7m"
      end
    end

    it "does not clear a light row's blank tail with el, which would drop the reverse video" do
      mono_window(12, 2, optimization: Crysterm::OptimizationFlag::BCE) do |window, output|
        box = Crysterm::Widget::Box.new parent: window, width: 12, height: 2, content: "hi"
        box.style.fg = 0x000000
        box.style.bg = 0xffffff
        window.repaint
        text = output.to_s
        text.should contain "\e[7m"
        text.should_not contain "\e[K" # the blanks are printed in reverse video, not erased
      end
    end
  end
end
