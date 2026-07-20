require "./spec_helper"

include Crysterm

# Regression specs for two BUGS16 media findings:
#
# * B16-53 — `Media::Tek#animate_loop` entered Tek mode once (`ESC[?38h`) and
#   held it across every per-frame `sleep` for the whole run. While xterm is in
#   Tek mode the concurrent VT100 window render bytes are interpreted as
#   Tektronix vector data, corrupting both displays. Fix: each frame emits
#   enter+draw+leave as one atomic write (mirroring the still path), so the
#   terminal is never left in Tek mode between frames.
#
# * B16-54 — `Media::Cells#render`'s animation branch made the still fallback
#   unreachable, so an animated cell backend painted a blank box until the
#   background frame composite finished. Fix: fall back to the still (frame 1 via
#   `png.bmp`) synchronously while the frames build, and re-compose it on resize.

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def cells_window(w = 24, h = 12)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, optimization: Crysterm::OptimizationFlag::None)
end

# A multi-frame APNG (num_plays 0, so it loops) written to *path*.
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

private def occurrences(s : String, sub : String) : Int32
  s.split(sub).size - 1
end

# Exposes the private state the B16-54 fix is about.
private class SpyAnsi < Crysterm::Widget::Media::Ansi
  def animated? : Bool
    @animated
  end

  def sample_present? : Bool
    !@sample.nil?
  end

  def sample_cols : Int32
    (@sample.try(&.[0]?).try(&.size)) || 0
  end
end

describe "B16-53 Media::Tek animation must not hold Tek mode across frames" do
  it "closes Tek mode after every frame (never held across a sleep)" do
    path = File.tempname("bugs16_tek", ".png")
    write_frames_apng path
    begin
      s = headless_screen
      output = s.output.as(IO::Memory)
      tek = Crysterm::Widget::Media::Tek.new file: path, parent: s

      tek.draw_tek # spawns the animation loop
      tek.playing?.should be_true

      # Let the loop emit at least one frame, then snapshot while it is asleep
      # between frames (the window in which the buggy code held Tek mode open).
      entered = false
      200.times do
        sleep 1.millisecond
        break if (entered = output.to_s.includes?("\e[?38h"))
      end
      entered.should be_true

      dump = output.to_s
      enters = occurrences(dump, "\e[?38h") # ESC [ ? 38 h  -> enter Tek
      exits = occurrences(dump, "\e\u{03}") # ESC ETX      -> back to VT100
      enters.should be > 0
      # The bug left enters unbalanced (mode held open). The fix pairs every
      # enter with an exit, so the terminal is back in VT100 between frames.
      exits.should eq enters
    ensure
      tek.try &.stop
      s.try &.destroy
      File.delete?(path)
    end
  end
end

describe "B16-54 animated cell backend must show the first frame immediately" do
  it "composes the still fallback before the background frames are ready" do
    path = File.tempname("bugs16_cells", ".png")
    write_frames_apng path
    begin
      s = cells_window
      img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 8, height: 8, file: path)
      img.animated?.should be_true

      # Render WITHOUT letting the background composite fiber run: @src_frames is
      # still nil here. The buggy render left @sample nil (blank box); the fix
      # composes the still fallback so something is painted right away.
      img.frames_ready?.should be_false
      s.repaint
      img.sample_present?.should be_true
    ensure
      img.try &.stop
      s.try &.destroy
      File.delete?(path)
    end
  end

  it "re-composes the fallback at the new size on a resize during the build" do
    path = File.tempname("bugs16_cells2", ".png")
    write_frames_apng path
    begin
      s = cells_window
      img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 8, height: 8, file: path)
      img.frames_ready?.should be_false
      s.repaint
      img.sample_cols.should eq 8

      # Resize while the frames are still building: the fallback still must be
      # re-composed at the new width, not kept at the old one.
      img.width = 12
      img.frames_ready?.should be_false
      s.repaint
      img.sample_cols.should eq 12
    ensure
      img.try &.stop
      s.try &.destroy
      File.delete?(path)
    end
  end
end
