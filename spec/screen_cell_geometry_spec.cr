require "./spec_helper"

include Crysterm

private def make_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 80, height: 24)
end

# A screen whose size is not pinned at construction, so it tracks the
# terminal's reported size. Over an `IO::Memory` (non-tty) output the ioctl
# probe falls back to 80x24, letting us tell an in-band-driven size apart
# from an ioctl-driven one.
private def make_dynamic_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new)
end

# An in-band resize report carries the new window size in pixels; the screen
# refreshes its cell pixel size and the CSS cell aspect ratio straight from it.
describe "Window cell geometry" do
  # Every test builds a fresh screen: drop any anchor claim a prior test's (or
  # spec file's) screen left behind, or the first-device-anchors policy would
  # block this test's screen from writing the global CSS anchors — and drop
  # this test's claim afterwards for the same reason.
  before_each { Crysterm::CSS::Length.measured_source = nil }
  after_each { Crysterm::CSS::Length.measured_source = nil }
  it "refreshes cell pixel size and CSS aspect ratio from an in-band resize report" do
    s = make_screen
    begin
      # 960x720 px over 80x24 cells -> 12x30 px cell -> aspect 2.5.
      ev = ::Tput::InputEvent.new('\0',
        resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 720, pixel_width: 960))
      s.handle_input ev
      s.cell_pixel_width.should eq 12
      s.cell_pixel_height.should eq 30
      Crysterm::CSS::Length.cell_aspect_ratio.should eq 2.5
    ensure
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
      Crysterm::CSS::Length.divisors["px"] = 10.0
    end
  end

  it "ignores a zero-pixel resize report (terminal reports no pixel size)" do
    s = make_screen
    Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    ev = ::Tput::InputEvent.new('\0',
      resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 0, pixel_width: 0))
    s.handle_input ev
    s.cell_pixel_width.should eq 0
    s.cell_pixel_height.should eq 0
    Crysterm::CSS::Length.cell_aspect_ratio.should eq 2.0 # unchanged
  end

  it "drives the screen dimensions from the in-band report, not the ioctl re-probe" do
    s = make_dynamic_screen
    # The report's 120x40 differs from the 80x24 ioctl fallback, so observing
    # 120x40 proves the report drove the resize, not a `reset_screen_size` re-probe.
    ev = ::Tput::InputEvent.new('\0',
      resize: ::Tput::Resize.new(rows: 40, cols: 120, pixel_height: 0, pixel_width: 0))
    s.handle_input ev
    s.refresh_size
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
    s.handle_input ev
    s.refresh_size
    s.awidth.should eq 80
    s.aheight.should eq 24
  end

  it "feeds the measured cell width into the CSS px divisor" do
    s = make_screen
    begin
      # 960x720 px over 80x24 cells -> 12px cell width.
      ev = ::Tput::InputEvent.new('\0',
        resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 720, pixel_width: 960))
      s.handle_input ev
      Crysterm::CSS::Length.divisors["px"].should eq 12.0
      # A `px` length now maps through the real cell width: 240px / 12 = 20 cells.
      Crysterm::CSS::Length.to_cells("240px").should eq 20
    ensure
      Crysterm::CSS::Length.divisors["px"] = 10.0
      Crysterm::CSS::Length.divisors["pt"] = 7.5
      Crysterm::CSS::Length.divisors["pc"] = 0.625
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end

  it "re-derives pt/pc from the measured px anchor (fixed CSS ratios)" do
    s = make_screen
    begin
      ev = ::Tput::InputEvent.new('\0',
        resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 720, pixel_width: 960))
      s.handle_input ev
      # px re-anchored to 12 → pt = 12 × 72/96 = 9, pc = 12 ÷ 16 = 0.75, so
      # `72pt` == `96px` == 8 cells — the units keep agreeing after the measure.
      Crysterm::CSS::Length.divisors["pt"].should eq 9.0
      Crysterm::CSS::Length.divisors["pc"].should eq 0.75
      Crysterm::CSS::Length.to_cells("72pt").should eq 8
      Crysterm::CSS::Length.to_cells("96px").should eq 8
    ensure
      Crysterm::CSS::Length.divisors["px"] = 10.0
      Crysterm::CSS::Length.divisors["pt"] = 7.5
      Crysterm::CSS::Length.divisors["pc"] = 0.625
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end

  it "leaves a css.unit_divisors-configured unit alone when re-deriving" do
    Superconf.css_unit_divisors = "pt=6"
    begin
      s = make_screen # apply_config merges pt=6 at construction
      ev = ::Tput::InputEvent.new('\0',
        resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 720, pixel_width: 960))
      s.handle_input ev
      Crysterm::CSS::Length.divisors["px"].should eq 12.0
      Crysterm::CSS::Length.divisors["pt"].should eq 6.0  # user-configured: untouched
      Crysterm::CSS::Length.divisors["pc"].should eq 0.75 # unconfigured: follows px
    ensure
      Superconf.css_unit_divisors = ""
      Crysterm::CSS::Length.divisors["px"] = 10.0
      Crysterm::CSS::Length.divisors["pt"] = 7.5
      Crysterm::CSS::Length.divisors["pc"] = 0.625
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end

  it "does not override a config-pinned px_per_cell with the measured width" do
    Superconf.css_px_per_cell = 8.0
    begin
      # apply_config (at construction) pins px=8 from the config option.
      s = make_screen
      Crysterm::CSS::Length.divisors["px"].should eq 8.0
      ev = ::Tput::InputEvent.new('\0',
        resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 720, pixel_width: 960))
      s.handle_input ev
      s.cell_pixel_width.should eq 12                    # measured width still recorded
      Crysterm::CSS::Length.divisors["px"].should eq 8.0 # but px stays pinned
      # A pinned px anchor also pins its derived siblings — no re-derivation.
      Crysterm::CSS::Length.divisors["pt"].should eq 7.5
      Crysterm::CSS::Length.divisors["pc"].should eq 0.625
    ensure
      Superconf.css_px_per_cell = 10.0
      Crysterm::CSS::Length.divisors["px"] = 10.0
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end

  it "leaves px at the 10.0 default when the terminal reports no pixel size" do
    s = make_screen
    Crysterm::CSS::Length.divisors["px"] = 10.0
    ev = ::Tput::InputEvent.new('\0',
      resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 0, pixel_width: 0))
    s.handle_input ev
    Crysterm::CSS::Length.divisors["px"].should eq 10.0 # unchanged
  end

  it "records pixels but does not override a config-pinned aspect ratio" do
    Superconf.css_cell_aspect_ratio = 3.0
    s = make_screen
    begin
      ev = ::Tput::InputEvent.new('\0',
        resize: ::Tput::Resize.new(rows: 24, cols: 80, pixel_height: 720, pixel_width: 960))
      s.handle_input ev
      s.cell_pixel_width.should eq 12 # pixels still recorded (e.g. for media)
      s.cell_pixel_height.should eq 30
      Crysterm::CSS::Length.cell_aspect_ratio.should eq 3.0 # pinned, not 2.5
    ensure
      Superconf.css_cell_aspect_ratio = 2.0
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
      Crysterm::CSS::Length.divisors["px"] = 10.0
    end
  end
end
