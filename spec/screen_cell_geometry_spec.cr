require "./spec_helper"

include Crysterm

private def make_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 80, height: 24)
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
