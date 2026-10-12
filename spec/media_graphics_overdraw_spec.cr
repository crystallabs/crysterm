require "./spec_helper"

include Crysterm

# A terminal-graphics backend that emits its picture only when it changes
# (`Media::Kitty`) emits it again, after the frame's cells, when the terminal
# may have lost it since: cells written over its rectangle (a terminal keeping
# images in its cells erases them; the full re-emission once the terminal's
# colors are known writes every cell, blanks included) or a screen clear
# (`ED 2` deletes kitty's images). It used to stay covered until it moved,
# as a picture in a view did until the view was scrolled
# (`Window#overdrawn?`).

private IMAGE_DIR = File.expand_path("#{__DIR__}/../data/image")

private def overdraw_window(output : IO::Memory, w = 40, h = 12)
  Window.new(input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def solid(w = 4, h = 4) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(200u8, 10u8, 10u8, 255u8) } }
end

# The output of one repaint of *s*.
private def frame(s : Window, buf : IO::Memory) : String
  buf.clear
  s.repaint
  buf.to_s
end

# Where a Kitty placement (`a=T`) starts in *emitted*, or nil.
private def kitty_at(emitted : String) : Int32?
  emitted.index("\e_Ga=T")
end

describe "Window#overdrawn?" do
  it "tells whether a frame wrote cells in a rectangle, until the next Rendered" do
    buf = IO::Memory.new
    s = overdraw_window buf
    t = Widget::Box.new parent: s, top: 2, left: 10, width: 5, height: 1, content: "abc"
    seen = [] of Tuple(Bool, Bool, Bool)
    s.on(Event::Rendered) do
      seen << {s.overdrawn?(10, 2, 3, 1), s.overdrawn?(0, 0, 9, 2), s.overdrawn?(0, 3, 40, 9)}
    end
    frame s, buf # the first frame writes the whole surface
    frame s, buf
    seen.last.should eq({false, false, false})
    t.set_content "xyz"
    frame s, buf
    seen.last.should eq({true, false, false})
    s.realloc
    frame s, buf
    seen.last.should eq({true, true, true})
    frame s, buf
    seen.last.should eq({false, false, false})
  ensure
    s.try &.destroy
  end
end

describe "Media::Kitty overdraw" do
  it "places the picture after the frame's cells and again after cells were written over it" do
    buf = IO::Memory.new
    s = overdraw_window buf
    k = Widget::Media::Kitty.new parent: s, top: 1, left: 2, width: 8, height: 4,
      cell_pixel_width: 10, cell_pixel_height: 20
    k.bitmap = solid
    emitted = frame s, buf
    at = kitty_at(emitted).should_not be_nil
    # The frame's cells come first, then the picture on top of them.
    emitted.index("\e[2;").should_not be_nil
    emitted.index("\e[2;").not_nil!.should be < at
    # Nothing changed: no re-emit.
    kitty_at(frame s, buf).should be_nil
    # The full re-emission (as when the terminal's polarity arrives) writes
    # every cell, the blanks under the picture too: the picture follows them.
    s.invalidate_region 0, s.awidth, 0, s.aheight
    emitted = frame s, buf
    at = kitty_at(emitted).should_not be_nil
    emitted.rindex("\e[5;").not_nil!.should be < at
    kitty_at(frame s, buf).should be_nil
  ensure
    s.try &.destroy
  end

  it "places the picture again after a screen clear, and not for cells written beside it" do
    buf = IO::Memory.new
    s = overdraw_window buf
    k = Widget::Media::Kitty.new parent: s, top: 1, left: 2, width: 8, height: 4,
      cell_pixel_width: 10, cell_pixel_height: 20
    k.bitmap = solid
    t = Widget::Box.new parent: s, top: 2, left: 20, width: 10, height: 1, content: "abc"
    frame s, buf
    t.set_content "changed"
    kitty_at(frame s, buf).should be_nil
    s.realloc
    kitty_at(frame s, buf).should_not be_nil
    kitty_at(frame s, buf).should be_nil
  ensure
    s.try &.destroy
  end

  it "keeps a view's picture on top of the cells re-emitted once the terminal's colors are known" do
    Config.media_backend = Widget::Media::Backend::Kitty
    buf = IO::Memory.new
    s = overdraw_window buf
    tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: s.awidth, height: s.aheight
    tb.document.base_url = IMAGE_DIR
    tb.set_markdown "# Title\n\n![Matterhorn](matterhorn.png)\n\nAfter"
    emitted = frame s, buf
    tb.block_media[0].should be_a(Widget::Media::Kitty)
    at = kitty_at(emitted).should_not be_nil
    emitted.index("After").not_nil!.should be < at
    kitty_at(frame s, buf).should be_nil
    s.invalidate_region 0, s.awidth, 0, s.aheight
    emitted = frame s, buf
    at = kitty_at(emitted).should_not be_nil
    emitted.index("After").not_nil!.should be < at
  ensure
    Config.reset "media.backend"
    s.try &.destroy
  end
end
