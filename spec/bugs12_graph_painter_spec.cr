require "./spec_helper"

include Crysterm

private def blank_bitmap(w, h) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(0, 0, 0, 0) } }
end

private def overlay_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 6)
end

# Re-exposes the private `TextOverlay` stamping helpers so they can be exercised
# directly against a real `window.lines` grid.
private class OverlayProbe < Crysterm::Widget
  include Crysterm::Widget::Graph::TextOverlay

  def stamp_text(x, y, text, attr, lo, hi)
    put_text x, y, text, attr, lo, hi
  end

  def stamp_cell(x, y, ch, attr, lo, hi)
    put_cell x, y, ch, attr, lo, hi
  end
end

describe Crysterm::Widget::Graph::Painter do
  # --- Finding #19 -------------------------------------------------------------
  describe "fill_ring with non-finite radii (#19)" do
    it "returns promptly without raising when r_outer is +Infinity" do
      bmp = blank_bitmap(8, 8)
      p = Crysterm::Widget::Graph::Painter.new bmp
      p.pen = 0xFFFFFF
      # Without the finite-radius guard the `while r <= ro` spoke loop never
      # terminates. A wall-clock bound proves it now returns instead of hanging.
      elapsed = Time.measure do
        p.fill_ring 4.0, 4.0, 0.0, Float64::INFINITY
      end
      elapsed.should be < 2.seconds
    end

    it "returns promptly when r_inner is -Infinity" do
      bmp = blank_bitmap(8, 8)
      p = Crysterm::Widget::Graph::Painter.new bmp
      elapsed = Time.measure do
        p.fill_ring 4.0, 4.0, -Float64::INFINITY, 3.0
      end
      elapsed.should be < 2.seconds
    end

    it "does not raise for a NaN radius" do
      bmp = blank_bitmap(8, 8)
      p = Crysterm::Widget::Graph::Painter.new bmp
      p.fill_ring 4.0, 4.0, Float64::NAN, Float64::NAN
    end

    it "caps a huge finite radius to a bounded, prompt fill" do
      bmp = blank_bitmap(8, 8)
      p = Crysterm::Widget::Graph::Painter.new bmp
      p.pen = 0xFF0000
      # A huge finite r_outer would iterate the spoke loop for ages; the
      # ELLIPSE_R_MAX cap keeps it bounded. Small sweep keeps the spec quick.
      elapsed = Time.measure do
        p.fill_ring 4.0, 4.0, 0.0, 1.0e9, 0.0, 2.0
      end
      elapsed.should be < 2.seconds
      # It still paints the in-bounds portion (center outward), so output is
      # bounded but non-empty.
      bmp[4][4].r.should eq 255
    end

    it "still draws a normal finite ring" do
      bmp = blank_bitmap(16, 16)
      p = Crysterm::Widget::Graph::Painter.new bmp
      p.pen = 0x00FF00
      p.fill_ring 8.0, 8.0, 2.0, 5.0
      # Some pixel on the ring band got painted.
      painted = false
      16.times { |y| 16.times { |x| painted = true if bmp[y][x].g == 255 } }
      painted.should be_true
    end
  end
end

describe Crysterm::Widget::Graph::TextOverlay do
  # --- Finding #15 -------------------------------------------------------------
  describe "off-top / off-left label stamping (#15)" do
    it "put_text does not stamp onto the wrapped bottom row for a negative y" do
      s = overlay_screen
      probe = OverlayProbe.new parent: s, width: 10, height: 3
      last = s.lines.size - 1
      # Snapshot the bottom row before the (negative-row) stamp attempt.
      before = (0...s.lines[last].size).map { |x| s.lines[last][x].char }
      probe.stamp_text 0, -1, "HELLO", 0_i64, 0, 20
      after = (0...s.lines[last].size).map { |x| s.lines[last][x].char }
      after.should eq before
    end

    it "put_text does not wrap a negative column to the right end of the row" do
      s = overlay_screen
      probe = OverlayProbe.new parent: s, width: 10, height: 3
      right = s.lines[0].size - 1
      before = s.lines[0][right].char
      # x=-1 with a negative clip floor: char i=0 lands at cx=-1, which would
      # wrap to the last column unless `lo` is clamped to 0.
      probe.stamp_text -1, 0, "X", 0_i64, -5, 20
      s.lines[0][right].char.should eq before
    end

    it "put_cell does not stamp onto the wrapped bottom row for a negative y" do
      s = overlay_screen
      probe = OverlayProbe.new parent: s, width: 10, height: 3
      last = s.lines.size - 1
      before = (0...s.lines[last].size).map { |x| s.lines[last][x].char }
      probe.stamp_cell 0, -1, 'Z', 0_i64, 0, 20
      after = (0...s.lines[last].size).map { |x| s.lines[last][x].char }
      after.should eq before
    end

    it "put_cell rejects a negative column even with a negative clip floor" do
      s = overlay_screen
      probe = OverlayProbe.new parent: s, width: 10, height: 3
      right = s.lines[0].size - 1
      before = s.lines[0][right].char
      probe.stamp_cell -1, 0, 'Z', 0_i64, -5, 20
      s.lines[0][right].char.should eq before
    end

    it "put_text still stamps a normal in-range label" do
      s = overlay_screen
      probe = OverlayProbe.new parent: s, width: 10, height: 3
      probe.stamp_text 1, 0, "OK", 0_i64, 0, 20
      s.lines[0][1].char.should eq 'O'
      s.lines[0][2].char.should eq 'K'
    end
  end
end
