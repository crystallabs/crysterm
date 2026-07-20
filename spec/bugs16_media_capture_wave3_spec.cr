require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 wave-3 media/terminal/capture findings:
# B16-55, B16-56, B16-57, B16-58, B16-59.

private def mc3_screen(w = 40, h = 12)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h, default_quit_keys: false)
end

private def mc3_bitmap(w = 8, h = 8) : PNGGIF::Bitmap
  Array(Array(PNGGIF::Pixel)).new(h) do |y|
    Array(PNGGIF::Pixel).new(w) do |x|
      PNGGIF::Pixel.new((x * 30 % 256).to_u8, (y * 30 % 256).to_u8, 128u8, 255u8)
    end
  end
end

private DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def mc3_emu(cols = 10, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, DFL)
end

private def mc3_row(em, y)
  em.lines[em.ydisp + y].map(&.char).join.delete('\u0000').rstrip
end

# Exposes Media::Graphics' private payload caches (mirrors `SixelProbe` in
# bugs16_capture_sixel_spec.cr).
private class RegisProbe < Crysterm::Widget::Media::Regis
  def probe_payload_geom
    @payload_geom
  end
end

# Exposes Ueberzug's `@last` placement rect so the re-send trigger can be
# pinned without a helper process.
private class UeberzugProbe < Crysterm::Widget::Media::Ueberzug
  def probe_last
    @last
  end

  def probe_last=(v : Tuple(Int32, Int32, Int32, Int32)?)
    @last = v
  end
end

# B16-55 — Media::Ansi auto-size set the OUTER box to the native cellmap size,
# so with a border/padding the image was resampled down by the insets instead
# of rendering at native size.
describe "BUGS16 B16-55: Media::Ansi auto-size compensates border/padding insets" do
  it "sizes a bordered widget ihorizontal/ivertical larger than a plain one" do
    path = File.tempname("mc3_ansi", ".png")
    File.write path, PNGGIF.encode_png(mc3_bitmap)
    begin
      s = mc3_screen
      plain = Widget::Media::Ansi.new file: path, parent: s
      bordered = Widget::Media::Ansi.new file: path, parent: s,
        style: Crysterm::Style.new(border: true)

      plain.width.as(Int32).should be > 0
      bordered.width.as(Int32).should eq plain.width.as(Int32) + bordered.ihorizontal
      bordered.height.as(Int32).should eq plain.height.as(Int32) + bordered.ivertical
      bordered.ihorizontal.should eq 2
    ensure
      s.try &.destroy
    end
  ensure
    path.try { |p| File.delete? p }
  end
end

# B16-56 — same defect class as B16-52 (Sixel), in the ReGIS backend: a
# runtime `dither` change must drop the cached vector payload and request a
# render, or the stale bytes keep being re-emitted.
describe "BUGS16 B16-56: Media::Regis#dither= invalidates the cached payload" do
  it "drops the payload cache on a real change and no-ops on a same-value assignment" do
    s = mc3_screen
    img = RegisProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    img.bitmap = mc3_bitmap(40, 60)
    s.repaint
    img.probe_payload_geom.should_not be_nil

    img.dither = img.dither # no-op: cache must survive
    img.probe_payload_geom.should_not be_nil

    img.dither = Crysterm::Widget::Media::Dither::Ordered
    img.probe_payload_geom.should be_nil
  ensure
    s.try &.destroy
  end
end

# B16-57 — Ueberzug's `add` command (which serializes the scaler) is only
# re-sent when the placement rect changes, so a plain `property scaler` made a
# runtime scaler change a silent no-op. The setter now nils `@last` (like
# `#load`) so the next redraw re-sends.
describe "BUGS16 B16-57: Media::Ueberzug#scaler= forces a placement re-send" do
  it "nils the remembered rect on a real change, keeps it on a no-op" do
    s = mc3_screen
    img = UeberzugProbe.new parent: s, top: 0, left: 0, width: 10, height: 5
    img.probe_last = {0, 0, 10, 5}

    img.scaler = img.scaler # same value: no churn
    img.probe_last.should eq({0, 0, 10, 5})

    img.scaler = Crysterm::Widget::Media::Ueberzug::Scaler::Contain
    img.probe_last.should be_nil
  ensure
    s.try &.destroy
  end
end

# B16-58 — with autowrap off, a wide glyph printed at the last column stored a
# bare 2-wide lead with no CONTINUATION cell, which the widget copied into the
# window grid where it visually spilled one column outside the widget. It now
# degrades to a blank.
describe "BUGS16 B16-58: wide glyph at the last column with autowrap off" do
  it "degrades to a blank instead of storing a bare wide lead" do
    em = mc3_emu(3, 2)
    em.feed "\e[?7l"              # DECAWM off
    em.feed "abc"                 # cursor parked on the last column
    em.feed "あ"                   # 2-wide glyph that cannot fit
    mc3_row(em, 0).should eq "ab" # last column blanked, not a wide lead
    em.lines[em.ydisp][2].char.should eq ' '
    mc3_row(em, 1).should eq "" # nothing wrapped
  end

  it "degrades on a 1-column grid even with autowrap on" do
    em = mc3_emu(1, 2)
    em.feed "あ" # wraps once, lands back on the same impossible column
    mc3_row(em, 0).should eq ""
    mc3_row(em, 1).should eq ""
    em.lines[em.ydisp][0].char.should eq ' '
  end
end

# B16-59 — `feed_animation_frames` wrote the first frame manually AND let the
# FrameClock's immediate first tick write it again, duplicating frame 0 and
# stretching the clip by one frame period. The immediate tick is now skipped.
describe "BUGS16 B16-59: feed_animation_frames writes frame 0 exactly once" do
  it "emits only the manual first frame within a sub-interval duration" do
    w = mc3_screen 6, 2
    begin
      io = IO::Memory.new
      fsize = Crysterm::Capture.rgba(
        Crysterm::Capture.render(w, 0, w.awidth, 0, w.aheight)).size
      fsize.should be > 0

      # fps 2 → 0.5 s tick interval; a 0.05 s capture ends long before the
      # first scheduled tick, so only the manually-written frame may appear.
      # Pre-fix the clock's immediate tick duplicated frame 0 (2 frames).
      w.feed_animation_frames(io, 0, w.awidth, 0, w.aheight, 0.05.seconds, 2)

      (io.size % fsize).should eq 0
      (io.size // fsize).should eq 1
    ensure
      w.destroy
    end
  end
end
