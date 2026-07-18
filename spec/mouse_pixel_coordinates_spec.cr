require "./spec_helper"

include Crysterm

# SGR-Pixels (DEC 1016) sub-cell mouse coordinates: the `mouse.pixel_coordinates`
# config gate, the cell-size requirement, and the `Event::Mouse#px`/`#py`
# surface. Driven headlessly — `enable_mouse` writes the enable sequence to the
# device output, which we drain and inspect.

private def pixel_screen(output)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: output,
    error: IO::Memory.new)
end

private def drained(s, io)
  s.tput.flush
  str = io.to_s
  io.clear
  str
end

describe "SGR-Pixels mouse coordinates (DEC 1016)" do
  it "enables 1016 and caches the cell size when requested under the default Auto policy" do
    buf = IO::Memory.new
    s = pixel_screen buf
    s.screen.cell_pixel_width = 8
    s.screen.cell_pixel_height = 16
    drained s, buf

    s.enable_mouse(pixels: :on)
    out = drained s, buf
    out.should contain "\e[?1016h"
    s.tput.mouse_cell_pixels.should eq({8, 16})
  end

  it "does not enable 1016 under Auto when the application doesn't ask" do
    buf = IO::Memory.new
    s = pixel_screen buf
    s.screen.cell_pixel_width = 8
    s.screen.cell_pixel_height = 16
    drained s, buf

    s.enable_mouse
    out = drained s, buf
    out.should_not contain "1016"
    s.tput.mouse_cell_pixels.should be_nil
  end

  it "skips 1016 when the terminal reports no cell size, even if requested" do
    buf = IO::Memory.new
    s = pixel_screen buf
    s.screen.cell_pixel_width = 0
    s.screen.cell_pixel_height = 0
    drained s, buf

    s.enable_mouse(pixels: :on)
    out = drained s, buf
    out.should_not contain "1016"
    s.tput.mouse_cell_pixels.should be_nil
  end

  it "honors the config gate: On forces it, Off forbids it" do
    prev = Crysterm::Config.mouse_pixel_coordinates
    begin
      buf = IO::Memory.new
      s = pixel_screen buf
      s.screen.cell_pixel_width = 8
      s.screen.cell_pixel_height = 16
      drained s, buf

      Crysterm::Config.mouse_pixel_coordinates = Crysterm::PixelMouse::On
      s.enable_mouse # no explicit request; On forces it
      drained(s, buf).should contain "\e[?1016h"

      Crysterm::Config.mouse_pixel_coordinates = Crysterm::PixelMouse::Off
      s.enable_mouse(pixels: :on) # explicit request; Off vetoes it
      vetoed = drained(s, buf)
      vetoed.should_not contain "\e[?1016h"
      # The veto lands on an *active* pixel session, so the downgrade must
      # reach the terminal too (DECRST 1016), keeping it in sync with the
      # parser's cleared cell-size cache (BUGS15 #6/#7).
      vetoed.should contain "\e[?1016l"
      s.tput.mouse_cell_pixels.should be_nil
    ensure
      Crysterm::Config.mouse_pixel_coordinates = prev
    end
  end

  it "refreshes the cached cell size on a resize while pixel mode is active" do
    buf = IO::Memory.new
    s = pixel_screen buf
    s.screen.cell_pixel_width = 8
    s.screen.cell_pixel_height = 16
    s.enable_mouse(pixels: :on)
    s.tput.mouse_cell_pixels.should eq({8, 16})

    # A font/zoom change arrives as a new cell size.
    s.screen.apply_cell_pixels(10, 20)
    s.tput.mouse_cell_pixels.should eq({10, 20})
  end

  it "leaves the cache untouched by apply_cell_pixels when pixel mode is off" do
    buf = IO::Memory.new
    s = pixel_screen buf
    s.tput.mouse_cell_pixels.should be_nil
    s.screen.apply_cell_pixels(10, 20)
    s.tput.mouse_cell_pixels.should be_nil
  end

  it "surfaces px/py on Event::Mouse for a pixel-encoded report" do
    ev = ::Tput::Mouse.parse_sgr_pixels 0, 100, 50, 'M', 8, 16
    m = Crysterm::Event::Mouse.new ev
    m.px.should eq 99
    m.py.should eq 49
    m.x.should eq 12
    m.y.should eq 3
  end

  it "leaves px/py nil for an ordinary cell-encoded report" do
    ev = ::Tput::Mouse.parse_sgr 0, 10, 20, 'M'
    m = Crysterm::Event::Mouse.new ev
    m.px.should be_nil
    m.py.should be_nil
  end
end
