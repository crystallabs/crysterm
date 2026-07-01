require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Media.new`'s `double_buffer:` forwarding.
#
# The factory builds the graphics backend with its own default
# (`media.double_buffer`, `true`) then overrides it from `double_buffer:`.
# The override used a plain truthiness test (`if (db = double_buffer)`), so
# an explicit `double_buffer: false` was silently dropped. Fixed by
# distinguishing "not given" (nil) from an explicit `false`.

private def render_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

describe "Widget::Media.new double_buffer: forwarding" do
  it "honours an explicit double_buffer: false on a graphics backend" do
    s = render_screen
    img = Crysterm::Widget::Media.new(
      type: Crysterm::Widget::Media::Type::Sixel, parent: s, double_buffer: false)
    img.as(Crysterm::Widget::Media::Graphics).double_buffer?.should be_false
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "honours an explicit double_buffer: true on a graphics backend" do
    s = render_screen
    img = Crysterm::Widget::Media.new(
      type: Crysterm::Widget::Media::Type::Sixel, parent: s, double_buffer: true)
    img.as(Crysterm::Widget::Media::Graphics).double_buffer?.should be_true
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "leaves the config default (true) in place when double_buffer: is omitted" do
    s = render_screen
    img = Crysterm::Widget::Media.new(
      type: Crysterm::Widget::Media::Type::Sixel, parent: s)
    img.as(Crysterm::Widget::Media::Graphics).double_buffer?.should be_true
  ensure
    img.try &.stop
    s.try &.destroy
  end
end
