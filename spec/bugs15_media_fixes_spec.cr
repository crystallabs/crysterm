require "./spec_helper"

include Crysterm

# Regression specs for four BUGS15 media-widget findings:
#
# * #71 — every backend constructor took `speed:` as a direct `@speed` ivar
#   assignment, bypassing the validating `Media::Base#speed=` clamp. A
#   `speed: 0`/NaN/Infinity therefore reached the playback pacers, which divide
#   by `@speed`, and killed the animation fiber. Fix: route the constructor arg
#   through `self.speed = speed`.
#
# * #81 — `Media::Ueberzug#load` nilled `@last` unconditionally, so after a
#   FAILED load (`local_path` nil) `remove` (guarded by `return if @last.nil?`)
#   became a no-op and the previous image stayed on screen forever. Fix: when the
#   new path is unusable, call `remove` (takes the stale placement down) instead
#   of nilling `@last`.
#
# * #83 — the ANSI-art decoder never wrapped at the right margin, so newline-less
#   80-column .ans files (the bulk of the BBS corpus) collapsed onto one row. Fix:
#   ANSI.SYS-style autowrap on sequential printing (width from a trailing SAUCE
#   record's TInfo1, else 80); explicit CUP positioning stays unwrapped.
#
# * #84 — a manual `#play` on an `animate: false` cell-grid image never animated:
#   `#render`'s branch was gated on the load-time `@animated` latch (still false),
#   so the still was repainted forever while the frame clock spun. Fix: the gate
#   also follows live playback (`@playing && @src_frames`).

private def media_window(w = 24, h = 12)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, optimization: Crysterm::OptimizationFlag::None)
end

# A multi-frame APNG with distinctly-colored frames and a very long per-frame
# delay, so the frame clock doesn't tick during the test — the spec drives
# `anim_index` by hand. Written to *path*.
private def write_slow_frames_apng(path : String, nframes = 4, w = 8, h = 8, delay = 100_000)
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

# Exposes the cell-backend `@animated` latch for #84.
private class SpyAnsi84 < Crysterm::Widget::Media::Ansi
  def animated? : Bool
    @animated
  end
end

# Signature of the widget's rendered cells (attr + char), so frame changes are
# observable.
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

# Records the JSON protocol a Ueberzug widget would emit, and exposes @last/@path,
# without a helper process or network. `send` is stubbed so `remove`/`redraw`
# still record their commands headlessly; `fetch_bytes` fails offline so a URL
# source deterministically yields a nil local path.
private class SpyUeberzug < Crysterm::Widget::Media::Ueberzug
  getter commands = [] of String

  def peek_last
    @last
  end

  def peek_path
    @path
  end

  def force_last(rect : Tuple(Int32, Int32, Int32, Int32))
    @last = rect
  end

  private def send(command, retry_once = true)
    @commands << command.to_json
  end

  protected def fetch_bytes(file : String) : Bytes
    raise "offline: no network in spec"
  end
end

describe "BUGS15 #71 constructor speed: bypasses the validating clamp" do
  it "clamps speed: 0 / NaN / Infinity to 1.0 for every backend" do
    s = media_window
    begin
      # Every media backend, constructed via the `speed:` argument. Before the
      # fix each assigned `@speed` directly, bypassing the clamp, so a zero /
      # NaN / Infinity reached the pacers and crashed the animation fiber.
      Crysterm::Widget::Media::Ansi.new(parent: s, speed: 0.0).speed.should eq 1.0
      Crysterm::Widget::Media::Ansi.new(parent: s, speed: Float64::NAN).speed.should eq 1.0
      Crysterm::Widget::Media::Ansi.new(parent: s, speed: Float64::INFINITY).speed.should eq 1.0
      Crysterm::Widget::Media::Ansi.new(parent: s, speed: -3.0).speed.should eq 1.0

      Crysterm::Widget::Media::Glyph.new(parent: s, speed: 0.0).speed.should eq 1.0
      Crysterm::Widget::Media::Tek.new(parent: s, speed: 0.0).speed.should eq 1.0
      Crysterm::Widget::Media::Overlay.new(parent: s, speed: 0.0).speed.should eq 1.0
      Crysterm::Widget::Media::Ueberzug.new(parent: s, speed: 0.0).speed.should eq 1.0
      # Graphics family (concrete: Kitty).
      Crysterm::Widget::Media::Kitty.new(parent: s, speed: Float64::INFINITY).speed.should eq 1.0
    ensure
      s.try &.destroy
    end
  end

  it "passes a valid speed through unchanged" do
    s = media_window
    begin
      Crysterm::Widget::Media::Ansi.new(parent: s, speed: 2.5).speed.should eq 2.5
      Crysterm::Widget::Media::Glyph.new(parent: s, speed: 0.5).speed.should eq 0.5
      Crysterm::Widget::Media::Kitty.new(parent: s, speed: 3.0).speed.should eq 3.0
    ensure
      s.try &.destroy
    end
  end
end

describe "BUGS15 #83 ANSI-art decoder 80-column autowrap" do
  # Sub-cell block size, derived from a 1x1 decode, so the assertions hold
  # regardless of the media.ansi_art_detail resolution.
  one = Crysterm::Widget::Media.decode_ansi("A".to_slice)
  block_w = one.width
  block_h = one.height

  it "wraps a newline-less 160-char row into two 80-column rows" do
    png = Crysterm::Widget::Media.decode_ansi(("A" * 160).to_slice)
    png.width.should eq block_w * 80 # 80 columns, not 160
    png.height.should eq block_h * 2 # wrapped onto a second row
  end

  it "honours a trailing SAUCE record's character width (TInfo1)" do
    sauce = Bytes.new(128, 0u8)
    "SAUCE00".to_slice.copy_to(sauce)
    sauce[94] = 1u8  # DataType = Character
    sauce[96] = 40u8 # TInfo1 low byte = 40 columns
    sauce[97] = 0u8  # TInfo1 high byte

    data = Bytes.new(160 + 1 + 128)
    ("A" * 160).to_slice.copy_to(data[0, 160])
    data[160] = 0x1A_u8 # SUB / DOS EOF marker before the SAUCE footer
    sauce.copy_to(data[161, 128])

    png = Crysterm::Widget::Media.decode_ansi(data)
    png.width.should eq block_w * 40 # wrap width taken from SAUCE
    png.height.should eq block_h * 4 # 160 / 40 = 4 rows
  end

  it "does not wrap explicit cursor positioning (CUP past column 80)" do
    # CUP to row 1, column 100 then print — the glyph must land at column 100,
    # not be folded back onto a new row by the sequential-printing autowrap.
    png = Crysterm::Widget::Media.decode_ansi("\e[1;100HA".to_slice)
    png.width.should eq block_w * 100
    png.height.should eq block_h * 1
  end
end

describe "BUGS15 #84 manual #play on an animate:false cell image animates" do
  it "takes the animation path (render follows anim_index) while playing" do
    path = File.tempname("bugs15_84", ".png")
    write_slow_frames_apng path
    begin
      s = media_window
      img = SpyAnsi84.new(parent: s, top: 0, left: 0, width: 12, height: 8,
        file: path, animate: false)
      # animate: false — the load-time latch is off and nothing auto-plays.
      img.animated?.should be_false
      img.playing?.should be_false

      img.play # user-initiated playback
      400.times do
        break if img.frames_ready?
        sleep 1.millisecond
      end
      img.frames_ready?.should be_true
      img.playing?.should be_true

      # With a long per-frame delay the clock won't advance during the test, so
      # anim_index is ours to drive. The render must follow it (the bug froze on
      # frame 0 because the gate consulted @animated, still false).
      img.anim_index = 0
      s.repaint
      sig0 = cell_sig(s, img)
      img.anim_index = 2
      s.repaint
      sig2 = cell_sig(s, img)
      sig0.should_not eq sig2
    ensure
      img.try &.stop
      s.try &.destroy
      File.delete?(path)
    end
  end

  it "returns to the still path once stopped (anim_index no longer matters)" do
    path = File.tempname("bugs15_84b", ".png")
    write_slow_frames_apng path
    begin
      s = media_window
      img = SpyAnsi84.new(parent: s, top: 0, left: 0, width: 12, height: 8,
        file: path, animate: false)
      img.play
      400.times do
        break if img.frames_ready?
        sleep 1.millisecond
      end
      img.frames_ready?.should be_true

      img.stop
      img.playing?.should be_false
      img.animated?.should be_false

      # Stopped: the still path ignores anim_index, so both renders match.
      img.anim_index = 0
      s.repaint
      still0 = cell_sig(s, img)
      img.anim_index = 2
      s.repaint
      still2 = cell_sig(s, img)
      still0.should eq still2
    ensure
      img.try &.stop
      s.try &.destroy
      File.delete?(path)
    end
  end
end

describe "BUGS15 #81 Ueberzug failed load takes the stale placement down" do
  it "issues remove (clearing @last) when the new source is unusable" do
    uz = SpyUeberzug.new
    uz.load("some/local/good.png") # non-URL: expands, so @path is usable
    uz.peek_path.should_not be_nil
    uz.peek_last.should be_nil # usable path forces a re-add, not a remove

    uz.force_last({0, 0, 4, 3}) # simulate a live placement on screen
    uz.commands.clear

    # A URL source whose fetch fails -> local_path nil -> @path nil.
    uz.load("https://host.invalid/broken.png")
    uz.peek_path.should be_nil
    uz.peek_last.should be_nil # placement taken down (not orphaned)
    uz.commands.any?(&.includes?("remove")).should be_true
  end

  it "does not emit a remove when the new path is usable (re-add replaces it)" do
    uz = SpyUeberzug.new
    uz.force_last({0, 0, 4, 3})
    uz.commands.clear

    uz.load("another/good.png") # usable -> just force a re-add
    uz.peek_last.should be_nil
    uz.commands.any?(&.includes?("remove")).should be_false
  end
end
