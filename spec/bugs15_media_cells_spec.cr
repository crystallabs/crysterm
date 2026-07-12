require "./spec_helper"

include Crysterm

# Regression specs for two BUGS15 media/cell-backend findings:
#
# * #13 — `Media::Ansi#colors=` / `#dither=` were plain `property` setters. The
#   reduced-color render path memoizes a whole dithered color plane
#   (`@dither_plane_memo`) and per-pixel nearest-palette lookups (`@quant_cache`),
#   neither keyed on `@colors`/`@dither` and neither invalidated by the setters.
#   So switching among the reduced modes (C256/C16/C8) — or the dither method —
#   at runtime kept painting the OLD palette/dither indefinitely. Fix: explicit
#   setters that drop the caches and request a render on a genuine change.
#
# * #22 — `Media::Base#fit=` calls `#reset_sample_cache`, which (for cell
#   backends) also set `@animated = false`. Nothing but `#load` recomputes
#   `@animated`, so changing `fit=` on a playing animation permanently froze it:
#   `#render`'s animation branch was skipped forever while the frame clock kept
#   ticking. Fix: `#reset_sample_cache` is source-neutral; `@animated` is cleared
#   only where the source is actually replaced (`#bitmap=`, `#clear_image`).

private def cells_window(w = 24, h = 12)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, optimization: Crysterm::OptimizationFlag::None)
end

# A colorful gradient so the C256/C16/C8 palettes (and the dither methods) each
# quantize it to a visibly different set of cells.
private def gradient_bmp(w = 8, h = 8) : PNGGIF::Bitmap
  Array.new(h) do |y|
    Array.new(w) do |x|
      PNGGIF::Pixel.new((x * 30 % 256).to_u8, (y * 30 % 256).to_u8, ((x + y) * 20 % 256).to_u8, 255u8)
    end
  end
end

# A multi-frame APNG with distinctly-colored frames, written to *path*.
private def write_frames_apng(path : String, nframes = 4, w = 8, h = 8, delay = 20)
  frames = [] of Tuple(PNGGIF::Bitmap, Int32)
  nframes.times do |i|
    r = ((i * 70 + 30) % 256).to_u8
    g = ((i * 40 + 10) % 256).to_u8
    b = ((i * 90 + 20) % 256).to_u8
    bmp = Array.new(h) { |y| Array.new(w) { |x| PNGGIF::Pixel.new(r, ((g.to_i + x * 7) % 256).to_u8, ((b.to_i + y * 11) % 256).to_u8, 255u8) } }
    frames << {bmp, delay}
  end
  File.write path, PNGGIF.encode_apng(frames, num_plays: 0)
end

# Exposes the cell-backend `@animated` flag the #22 fix is about.
private class SpyAnsi < Crysterm::Widget::Media::Ansi
  def animated? : Bool
    @animated
  end
end

# Signature of the widget's rendered cells (attr + char), so palette/frame
# changes are observable.
private def cell_sig(s, img) : String
  lp = img.lpos.not_nil!
  String.build do |io|
    (lp.yi...lp.yl).each do |y|
      row = s.lines[y]? || next
      (lp.xi...lp.xl).each do |x|
        cell = row[x]? || next
        io << cell.attr << ':' << cell.char << ';'
      end
    end
  end
end

describe "BUGS15 #13 Media::Ansi#colors=/#dither= runtime palette change" do
  it "re-quantizes to the new palette instead of serving the stale plane" do
    s = cells_window
    img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 8, height: 8,
      colors: Crysterm::Widget::Media::Ansi::ColorMode::C256, animate: false)
    img.bitmap = gradient_bmp # single-frame still
    s._render
    sig256 = cell_sig(s, img)

    # Genuine palette change: before the fix the memoized C256 plane kept
    # painting the 256-color look here.
    img.colors = Crysterm::Widget::Media::Ansi::ColorMode::C8
    s._render
    sig8 = cell_sig(s, img)
    sig8.should_not eq sig256

    # Switching back must re-derive the C256 look (memo not stuck on C8 either).
    img.colors = Crysterm::Widget::Media::Ansi::ColorMode::C256
    s._render
    cell_sig(s, img).should eq sig256
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "re-dithers when the dither method changes in a reduced mode" do
    s = cells_window
    img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 8, height: 8,
      colors: Crysterm::Widget::Media::Ansi::ColorMode::C16,
      dither: Crysterm::Widget::Media::Dither::Diffusion, animate: false)
    img.bitmap = gradient_bmp
    s._render
    sig_diff = cell_sig(s, img)

    img.dither = Crysterm::Widget::Media::Dither::Ordered
    s._render
    cell_sig(s, img).should_not eq sig_diff
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "is a no-op for a same-value assignment (no needless churn)" do
    s = cells_window
    img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 8, height: 8,
      colors: Crysterm::Widget::Media::Ansi::ColorMode::C256, animate: false)
    img.bitmap = gradient_bmp
    s._render
    sig = cell_sig(s, img)
    img.colors = Crysterm::Widget::Media::Ansi::ColorMode::C256 # unchanged
    s._render
    cell_sig(s, img).should eq sig
  ensure
    img.try &.stop
    s.try &.destroy
  end
end

describe "BUGS15 #22 fit= must not freeze a playing animation" do
  it "keeps @animated true across a fit change (frozen-animation regression)" do
    path = File.tempname("bugs15_fit", ".png")
    write_frames_apng path
    begin
      s = cells_window
      img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 8, height: 8, file: path)
      # An animated APNG auto-plays.
      img.animated?.should be_true
      img.playing?.should be_true

      # The regression: a genuine fit change (Stretch -> Contain) went through
      # reset_sample_cache, which used to clear @animated and freeze playback.
      img.fit = Crysterm::Widget::Media::Fit::Contain
      img.animated?.should be_true
      img.playing?.should be_true
    ensure
      img.try &.stop
      s.try &.destroy
      File.delete?(path)
    end
  end

  it "still renders distinct frames after a fit change" do
    path = File.tempname("bugs15_fit2", ".png")
    write_frames_apng path
    begin
      s = cells_window
      img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 12, height: 8, file: path)
      # Let the composite fiber build the frames, then pause to drive by hand.
      400.times do
        break if img.frames_ready?
        sleep 1.millisecond
      end
      img.frames_ready?.should be_true
      img.pause

      img.fit = Crysterm::Widget::Media::Fit::Contain

      img.anim_index = 0
      s._render
      sig0 = cell_sig(s, img)
      img.anim_index = 1
      s._render
      sig1 = cell_sig(s, img)
      # Frozen (buggy) render ignores anim_index and paints the still -> equal.
      sig0.should_not eq sig1
    ensure
      img.try &.stop
      s.try &.destroy
      File.delete?(path)
    end
  end

  it "clears @animated when the source is replaced by a still bitmap or cleared" do
    path = File.tempname("bugs15_fit3", ".png")
    write_frames_apng path
    begin
      s = cells_window
      img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 8, height: 8, file: path)
      img.animated?.should be_true

      img.bitmap = gradient_bmp # a directly-injected still
      img.animated?.should be_false

      img.set_image(path) # animated again
      img.animated?.should be_true
      img.clear_image
      img.animated?.should be_false
    ensure
      img.try &.stop
      s.try &.destroy
      File.delete?(path)
    end
  end
end
