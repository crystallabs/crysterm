require "./spec_helper"

include Crysterm

# Regression spec for `Widget::Media.new`'s `double_buffer:` forwarding.
#
# The factory builds the graphics backend with its own default
# (`media.double_buffer`, `true`) then overrides it from `double_buffer:`.
# The override must distinguish "not given" (nil) from an explicit `false` —
# a plain truthiness test (`if (db = double_buffer)`) silently drops
# `double_buffer: false`.

describe "Widget::Media.new double_buffer: forwarding" do
  it "honours an explicit double_buffer: false on a graphics backend" do
    s = headless_screen(80, 24, default_quit_keys: true)
    img = Crysterm::Widget::Media.new(
      type: Crysterm::Widget::Media::Type::Sixel, parent: s, double_buffer: false)
    img.as(Crysterm::Widget::Media::Graphics).double_buffer?.should be_false
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "honours an explicit double_buffer: true on a graphics backend" do
    s = headless_screen(80, 24, default_quit_keys: true)
    img = Crysterm::Widget::Media.new(
      type: Crysterm::Widget::Media::Type::Sixel, parent: s, double_buffer: true)
    img.as(Crysterm::Widget::Media::Graphics).double_buffer?.should be_true
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "leaves the config default (true) in place when double_buffer: is omitted" do
    s = headless_screen(80, 24, default_quit_keys: true)
    img = Crysterm::Widget::Media.new(
      type: Crysterm::Widget::Media::Type::Sixel, parent: s)
    img.as(Crysterm::Widget::Media::Graphics).double_buffer?.should be_true
  ensure
    img.try &.stop
    s.try &.destroy
  end
end
