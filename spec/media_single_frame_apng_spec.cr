require "./spec_helper"

include Crysterm

# Regression spec for `Media::Cells#load`'s "genuinely animated" gate.
#
# A single-frame APNG decodes to a `PNGGIF::PNG` whose `frames` is non-nil but
# holds exactly one frame (unlike a GIF, which leaves `frames` nil below two
# frames). `Media::Base#play` bails on a single frame and never builds
# `@src_frames`, but `Media::Cells#load` used `!frames.nil?` to set `@animated`,
# so the cell backends entered the animation branch, found no `@src_frames`,
# and drew nothing. Fix: gate `@animated` on `frames.size > 1`, matching `#play`.

private def headless_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def solid_bitmap(r, g, b, w = 4, h = 4) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(r, g, b, 255) } }
end

describe "Media::Cells single-frame APNG" do
  it "renders a 1-frame APNG as a still (not a blank animated widget)" do
    # Real single-frame APNG: acTL numFrames=1 + one fcTL + IDAT, so the
    # decoder yields `frames` non-nil with size 1.
    apng = PNGGIF.encode_apng([{solid_bitmap(10, 20, 30), 100}])
    tmp = File.tempfile("crysterm_apng", ".png")
    File.write(tmp.path, apng)

    s = headless_screen
    img = Crysterm::Widget::Media::Ansi.new(
      file: tmp.path, parent: s, top: 0, left: 0, width: 4, height: 4)

    s._render

    # A single frame is a still: playback must NOT engage.
    img.playing?.should be_false

    # Content cell must carry the image pixel's color. With the bug the
    # animation branch composed no sample and the cell stayed at screen default.
    cell = s.lines[0][0]
    Attr.bg(cell.attr).should eq Attr.pack_color(0x0a141e)
  ensure
    img.try &.stop
    s.try &.destroy
    tmp.try &.delete rescue nil
  end
end
