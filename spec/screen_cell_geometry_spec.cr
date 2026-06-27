require "./spec_helper"

include Crysterm

private def make_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 80, height: 24)
end

# A screen whose size is *not* pinned at construction, so it tracks the
# terminal's reported size. Over an `IO::Memory` (non-tty) output the ioctl
# probe falls back to the 80×24 default, which lets us tell an in-band-driven
# size apart from an ioctl-driven one.
private def make_dynamic_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new)
end

# An in-band resize report carries the new window size in pixels; the screen
# refreshes its cell pixel size and the CSS cell aspect ratio straight from it.
describe "Screen cell geometry" do
  it "refreshes cell pixel size and CSS aspect ratio from an in-band resize report" do
    s = make_screen
    begin
      # 960×720 px over 80×24 cells ⇒ a 12×30 px cell ⇒ aspect 2.5.
      ev = ::Tput::InputEvent.new('\0',
        resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 720, pixel_width: 960))
      s.dispatch_input ev
      s.cell_pixel_width.should eq 12
      s.cell_pixel_height.should eq 30
      Crysterm::CSS::Length.cell_aspect_ratio.should eq 2.5
    ensure
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end

  it "ignores a zero-pixel resize report (terminal reports no pixel size)" do
    s = make_screen
    Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    ev = ::Tput::InputEvent.new('\0',
      resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 0, pixel_width: 0))
    s.dispatch_input ev
    s.cell_pixel_width.should eq 0
    s.cell_pixel_height.should eq 0
    Crysterm::CSS::Length.cell_aspect_ratio.should eq 2.0 # unchanged
  end

  it "drives the screen dimensions from the in-band report, not the ioctl re-probe" do
    s = make_dynamic_screen
    # The report's 120×40 differs from the 80×24 the (non-tty) ioctl would
    # report, so observing 120×40 proves the authoritative report drove the
    # resize rather than a `reset_screen_size` re-probe.
    ev = ::Tput::InputEvent.new('\0',
      resize: ::Tput::Resize.new(rows: 40, cols: 120, pixel_height: 0, pixel_width: 0))
    s.dispatch_input ev
    s.resize
    s.awidth.should eq 120
    s.aheight.should eq 40
    # `tput`'s cached size is kept consistent too (e.g. for cursor clamping).
    s.tput.screen.width.should eq 120
    s.tput.screen.height.should eq 40
  end

  it "leaves an explicitly-sized (headless/fixed) screen's dimensions untouched" do
    s = make_screen # pinned 80×24 (@explicit_size)
    ev = ::Tput::InputEvent.new('\0',
      resize: ::Tput::Resize.new(rows: 40, cols: 120, pixel_height: 0, pixel_width: 0))
    s.dispatch_input ev
    s.resize
    s.awidth.should eq 80
    s.aheight.should eq 24
  end

  it "records pixels but does not override a config-pinned aspect ratio" do
    Superconf.css_cell_aspect_ratio = 3.0
    s = make_screen
    begin
      ev = ::Tput::InputEvent.new('\0',
        resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 720, pixel_width: 960))
      s.dispatch_input ev
      s.cell_pixel_width.should eq 12 # pixels still recorded (e.g. for media)
      s.cell_pixel_height.should eq 30
      Crysterm::CSS::Length.cell_aspect_ratio.should eq 3.0 # pinned, not 2.5
    ensure
      Superconf.css_cell_aspect_ratio = 2.0
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end
end
