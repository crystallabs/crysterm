require "./spec_helper"

include Crysterm

# BUGS11 #18 — Int32 overflow (OverflowError) in slider/scrollbar pointer<->value
# and thumb math when the value range is large.
#
# The transforms multiplied two Int32 quantities (pos * value_span,
# (slider_position - minimum) * room, (value - minimum) * avail) before the
# float divide, so a range span above ~Int32::MAX / track-length overflowed and
# raised OverflowError during a render or a track click. The fix promotes the
# first multiplicand to Float64 so the whole computation runs in Float64.

private def overflow_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def press(s, x, y)
  s._render
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

describe "slider/scrollbar large-range overflow (BUGS11 #18)" do
  it "renders a ScrollBar with a huge range without raising (thumb_offset)" do
    s = overflow_screen
    sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 25,
      minimum: 0, maximum: 200_000_000, value: 150_000_000
    # (slider_position - minimum) * room overflowed Int32 here.
    sb.value.should eq 150_000_000
    s._render # must not raise OverflowError
  end

  it "maps a track click on a large-range Slider without raising (value_at)" do
    s = overflow_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 60, height: 1,
      minimum: 0, maximum: 100_000_000, value: 0
    # pos * value_span at a large pos overflowed Int32 in value_at.
    press s, 50, 0 # must not raise OverflowError
    sl.value.should be >= 0
    sl.value.should be <= 100_000_000
    sl.value.should be > 0 # a click 50 cells in lands well inside the range
  end

  it "renders a large-range Slider with the handle in range (handle_offset)" do
    s = overflow_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 60, height: 1,
      minimum: 0, maximum: 100_000_000, value: 90_000_000
    s._render # handle_offset: (value - minimum) * avail must not overflow
    sl.value.should eq 90_000_000
  end

  it "renders a large-range Slider with tick marks without raising (draw_ticks)" do
    s = overflow_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 60, height: 3,
      minimum: 0, maximum: 100_000_000, value: 50_000_000,
      tick_position: Widget::Slider::TickPosition::Both,
      tick_interval: 10_000_000
    s._render # draw_ticks: (tv - minimum) * avail must not overflow
    sl.value.should eq 50_000_000
  end
end
