require "./spec_helper"

include Crysterm

# Builds a `Direct` writing into an in-memory output.
private def direct_io
  mem = IO::Memory.new
  d = Crysterm::Direct.new(
    input: IO::Memory.new,
    output: mem,
    error: IO::Memory.new,
  )
  {d, mem}
end

describe Crysterm::Direct do
  it "emits no escapes for unstyled text" do
    d, mem = direct_io
    d.print "plain"
    mem.to_s.should eq "plain"
  end

  it "wraps styled text in SGR + reset" do
    d, mem = direct_io
    d.print "hi", bold: true
    s = mem.to_s
    s.should start_with "\e["
    s.should contain "hi"
    s.should end_with "\e[0m"
    # Bold flag present.
    s.should contain "1"
  end

  it "reduces colors to the terminal depth" do
    mem = IO::Memory.new
    d = Crysterm::Direct.new(input: IO::Memory.new, output: mem, error: IO::Memory.new)
    # Pin a 16-color terminal so a truecolor value is reduced to an ANSI index.
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::Ansi
    d.print "x", fg: 0xff0000
    s = mem.to_s
    # Not emitted as a 24-bit `38;2;...` truecolor sequence.
    s.should_not contain "38;2"
    s.should contain "x"
  ensure
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::Auto
  end

  it "resolves a named color" do
    mem = IO::Memory.new
    d = Crysterm::Direct.new(input: IO::Memory.new, output: mem, error: IO::Memory.new)
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::TrueColor
    d.print "g", fg: "green"
    s = mem.to_s
    s.should contain "38;2"
    s.should contain "g"
  ensure
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::Auto
  end

  it "moves the cursor to an absolute position" do
    d, mem = direct_io
    d.move_yx 4, 9
    # CUP is 1-based on the wire.
    mem.to_s.should contain "\e[5;10H"
  end

  it "set_style / reset_styles bracket persistent output" do
    d, mem = direct_io
    d.set_style(bold: true)
    d.output << "raw"
    d.reset_styles
    s = mem.to_s
    s.should contain "raw"
    s.should end_with "\e[0m"
  end

  it "draws an ascii box of the requested size" do
    d, mem = direct_io
    d.box 0, 0, 3, 4, ascii: true
    s = mem.to_s
    s.should contain "+--+" # top and bottom edges
    s.should contain "|"    # verticals
  end

  it "reports device dimensions" do
    mem = IO::Memory.new
    d = Crysterm::Direct.new(input: IO::Memory.new, output: mem, error: IO::Memory.new)
    d.dim_x.should be > 0
    d.dim_y.should be > 0
  end
end
