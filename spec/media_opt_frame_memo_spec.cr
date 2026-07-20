require "./spec_helper"

include Crysterm

# Focused specs for the "OPT" media-pipeline optimizations:
#
#   M3 — `Media::Kitty` streams id-substituted payload segments into the output
#        builder instead of `gsub`-copying the whole payload per emit. Output
#        must stay byte-identical to the old two-`gsub` path.
#   M7 — the dither-plane / braille-threshold memo is keyed by animation frame
#        index (identity-validated), so a looping animation reuses each frame's
#        derived data across loops instead of recomputing every frame. Output
#        must equal an uncached (fresh-per-frame) render, and be loop-stable.

private def mk_window(w = 40, h = 20)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, optimization: Crysterm::OptimizationFlag::None)
end

private def solid_bmp(w = 4, h = 4) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(200u8, 100u8, 50u8, 255u8) } }
end

# A multi-frame APNG with distinctly-colored frames (so each frame dithers /
# thresholds to a different result), written to *path*.
private def write_multiframe_apng(path : String, nframes : Int32, w = 8, h = 8, delay = 20)
  frames = [] of Tuple(PNGGIF::Bitmap, Int32)
  nframes.times do |i|
    r = ((i * 70 + 30) % 256).to_u8
    g = ((i * 40 + 10) % 256).to_u8
    b = ((i * 90 + 20) % 256).to_u8
    bmp = Array.new(h) { |y| Array.new(w) { |x| PNGGIF::Pixel.new(r, ((g.to_i + x*7) % 256).to_u8, ((b.to_i + y*11) % 256).to_u8, 255u8) } }
    frames << {bmp, delay}
  end
  File.write path, PNGGIF.encode_apng(frames, num_plays: 0)
end

# Reference (old) Kitty finalize: two gsubs, parity toggled by the caller.
private def ref_finalize(k, payload : String, parity : Bool) : String
  if k.double_buffer?
    primary, other = parity ? {k.@id_b, k.@id_a} : {k.@id_a, k.@id_b}
    payload.gsub("{i}", primary.to_s).gsub("{o}", other.to_s)
  else
    payload.gsub("{i}", k.@id_a.to_s)
  end
end

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

# Plays *img* until its composited frames are ready, then pauses so frame
# indices can be driven by hand.
private def drive_ready(img)
  img.play
  400.times do
    break if img.frames_ready?
    sleep 1.millisecond
  end
  img.frames_ready?.should be_true
  img.pause
end

describe "Media::Kitty#emit_payload (M3)" do
  it "streams double-buffer output byte-identical to the old two-gsub path" do
    s = mk_window
    k = Crysterm::Widget::Media::Kitty.new parent: s, width: 4, height: 3
    bmp = solid_bmp
    k.bitmap = bmp
    k.double_buffer?.should be_true
    cached = k.encode(bmp, 4, 4, 0, 0, 4, 3)

    parity = false
    6.times do
      expected = ref_finalize(k, cached, parity)
      parity = !parity
      k.finalize_payload(cached).should eq expected # streamed == reference, per emit
    end
  ensure
    s.try &.destroy
  end

  it "streams single-buffer output byte-identical to the old gsub path" do
    s = mk_window
    k = Crysterm::Widget::Media::Kitty.new parent: s, width: 4, height: 3, double_buffer: false
    bmp = solid_bmp
    k.bitmap = bmp
    cached = k.encode(bmp, 4, 4, 0, 0, 4, 3)

    expected = ref_finalize(k, cached, false)
    f1 = k.finalize_payload(cached)
    f2 = k.finalize_payload(cached)
    f1.should eq expected
    f2.should eq expected # no buffer swap when double-buffering is off
    f1.should_not contain("{i}")
  ensure
    s.try &.destroy
  end
end

describe "Media::Cells::FrameMemo (M7)" do
  it "caches per frame index, revalidates on bitmap identity, and clears" do
    memo = Crysterm::Widget::Media::Cells::FrameMemo(Int32).new
    b0 = [[PNGGIF::Pixel.new(0u8, 0u8, 0u8, 255u8)]]
    b1 = [[PNGGIF::Pixel.new(1u8, 1u8, 1u8, 255u8)]]
    calls = 0

    memo.get(0, b0) { calls += 1; 10 }.should eq 10 # miss
    memo.get(0, b0) { calls += 1; 99 }.should eq 10 # hit (same idx+bmp)
    calls.should eq 1
    memo.get(1, b1) { calls += 1; 20 }.should eq 20 # miss (new idx)
    memo.get(0, b1) { calls += 1; 30 }.should eq 30 # miss (idx 0 but new bmp id)
    calls.should eq 3

    memo.delete(0)
    memo.get(0, b1) { calls += 1; 40 }.should eq 40 # miss after delete
    calls.should eq 4

    memo.clear
    memo.get(1, b1) { calls += 1; 50 }.should eq 50 # miss after clear
    calls.should eq 5
  end

  it "produces per-frame dither identical to a fresh render, stable across loops (Ansi C256)" do
    path = File.tempname("m7", ".png")
    write_multiframe_apng path, 4
    begin
      s = mk_window
      img = Crysterm::Widget::Media::Ansi.new parent: s, top: 0, left: 0, width: 12, height: 8,
        file: path, color_mode: Crysterm::Widget::Media::Ansi::ColorMode::C256
      drive_ready img

      n = 4
      pass1 = (0...n).map { |i| img.anim_index = i; s.repaint; cell_sig(s, img) }
      pass2 = (0...n).map { |i| img.anim_index = i; s.repaint; cell_sig(s, img) }
      pass1.should eq pass2         # loop-stable: same frame -> same cells
      pass1.uniq.size.should be > 1 # frames are genuinely distinct

      # Fresh widget per frame (no memo history) must match the looped output.
      (0...n).each do |i|
        rs = mk_window
        rimg = Crysterm::Widget::Media::Ansi.new parent: rs, top: 0, left: 0, width: 12, height: 8,
          file: path, color_mode: Crysterm::Widget::Media::Ansi::ColorMode::C256
        drive_ready rimg
        rimg.anim_index = i
        rs.repaint
        cell_sig(rs, rimg).should eq pass1[i]
        rimg.stop
        rs.destroy
      end
      img.stop
      s.destroy
    ensure
      File.delete?(path)
    end
  end

  it "produces per-frame braille threshold identical to a fresh render (Glyph)" do
    path = File.tempname("m7g", ".png")
    write_multiframe_apng path, 4
    begin
      s = mk_window
      img = Crysterm::Widget::Media::Glyph.new parent: s, top: 0, left: 0, width: 12, height: 8,
        file: path, mode: Crysterm::Widget::Media::Glyph::Mode::Braille
      drive_ready img
      n = 4
      pass1 = (0...n).map { |i| img.anim_index = i; s.repaint; cell_sig(s, img) }
      pass2 = (0...n).map { |i| img.anim_index = i; s.repaint; cell_sig(s, img) }
      pass1.should eq pass2

      (0...n).each do |i|
        rs = mk_window
        rimg = Crysterm::Widget::Media::Glyph.new parent: rs, top: 0, left: 0, width: 12, height: 8,
          file: path, mode: Crysterm::Widget::Media::Glyph::Mode::Braille
        drive_ready rimg
        rimg.anim_index = i
        rs.repaint
        cell_sig(rs, rimg).should eq pass1[i]
        rimg.stop
        rs.destroy
      end
      img.stop
      s.destroy
    ensure
      File.delete?(path)
    end
  end
end
