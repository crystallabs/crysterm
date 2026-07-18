require "./spec_helper"

include Crysterm

private def fps_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

describe Crysterm::Widget::Fps do
  it "renders the default R/D/FPS line, throughput and total" do
    s = fps_screen
    fps = Crysterm::Widget::Fps.new parent: s
    s._render

    # First frame has no prior measurements: every rate reads 0, and the
    # cumulative total is still 0 (draw bytes are counted after the widget
    # paints). Fields are padded to fixed widths.
    expected = Crysterm::Widget::Fps::DEFAULT_FORMAT % [0, 0, 0, 0, 0, 0, "0B", "0B", "0B", "0B", "0B"]
    fps.content.should eq expected
  end

  it "keeps a constant line length as the numbers change width (no jitter)" do
    # Fixed-width fields: small and large readings render to the same length,
    # so the auto-sized box never shrinks/grows a column.
    fmt = Crysterm::Widget::Fps::DEFAULT_FORMAT
    small = fmt % [0, 0, 0, 0, 0, 0, "0B", "0B", "0B", "0B", "0B"]
    large = fmt % [99999, 99999, 99999, 12345, 6789, 100, "1023.9MiB", "512.0KiB", "1023.9MiB", "512.0KiB", "8.0GiB"]
    large.size.should eq small.size
  end

  it "defaults to the bottom-left corner" do
    s = fps_screen
    fps = Crysterm::Widget::Fps.new parent: s
    fps.left.should eq 0
    fps.bottom.should eq 0
  end

  it "honors an explicit position instead of the default corner" do
    s = fps_screen
    fps = Crysterm::Widget::Fps.new parent: s, top: 2, left: 5
    fps.top.should eq 2
    fps.left.should eq 5
    fps.bottom.should be_nil
  end

  it "lets the user pick the format and which metrics to print" do
    s = fps_screen
    fps = Crysterm::Widget::Fps.new parent: s, format: "%s fps", args: [Crysterm::Widget::Fps::Metric::Fps]
    s._render
    fps.content.should eq "0 fps"
  end

  it "surfaces a bad format/args combination instead of crashing the render" do
    s = fps_screen
    # %d on a String arg raises inside String#%; the widget must catch it.
    fps = Crysterm::Widget::Fps.new parent: s, format: "%d", args: [Crysterm::Widget::Fps::Metric::TotalH]
    s._render
    fps.content.should start_with "FPS format error"
  end

  it "accumulates the cumulative byte total across frames" do
    s = fps_screen
    fps = Crysterm::Widget::Fps.new parent: s, format: "%s", args: [Crysterm::Widget::Fps::Metric::Total]

    # Frame 1 draws the overlay text, so the running total grows above 0.
    s._render
    first_total = s.bytes_written
    first_total.should be > 0

    # Frame 2: widget reports bytes emitted before this frame's draw (frame
    # 1's total), while the running total keeps climbing.
    s._render
    fps.content.to_i.should eq first_total
    s.bytes_written.should be >= first_total
  end
end

describe "Window performance measurements" do
  it "exposes per-frame rates and a growing byte total" do
    s = fps_screen
    # Something must be on screen for `draw` to emit output.
    Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 1, content: "hello"
    s._render
    s.render_rate.should be >= 0
    s.draw_rate.should be >= 0
    s.frame_rate.should be >= 0
    s.throughput.should be >= 0
    s.bytes_written.should be > 0
  end

  it "reports wall-clock throughput only once there is a prior frame" do
    s = fps_screen
    Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 1, content: "hello"

    # First frame: no previous start to measure the real interval against.
    s._render
    s.throughput_actual.should eq 0

    # Second frame: now measured over wall-clock time between the two frames.
    s._render
    s.throughput_actual.should be >= 0
  end
end
