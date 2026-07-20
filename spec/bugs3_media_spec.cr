require "./spec_helper"

include Crysterm

# Regression specs for the "BUGS3" batch of media/effect/transition fixes:
#
#   1. Kitty double-buffering keys on a monotonic emit parity (`@buffer_parity`)
#      instead of `@anim_index` parity, so streaming video (anim_index pinned to
#      0) and odd-length animations still alternate the `@id_a`/`@id_b` buffers.
#   2. A finite media animation (`num_plays` reached) holds the LAST frame on
#      completion instead of snapping back to frame 0.
#   3. `transition_color`/`transition_float` cancel any in-flight tween BEFORE
#      their early returns (nil / equal target), so a stale tween is stopped.
#   4. `Effect::Fire#decay=` clamps to `0.0..1.0` (constructor routed through it).

private def headless_window(w = 10, h = 5)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

# A tiny in-memory APNG with *nframes* solid frames and the given loop count
# (`num_plays`; 0 = forever). Written to *path* so a `Media` backend can load it.
private def write_apng(path : String, nframes : Int32, num_plays : Int32,
                       w = 4, h = 4, delay = 20)
  frames = [] of Tuple(PNGGIF::Bitmap, Int32)
  nframes.times do |i|
    v = ((i * 60) % 256).to_u8
    bmp = Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(v, 0u8, 0u8, 255u8) } }
    frames << {bmp, delay}
  end
  File.write path, PNGGIF.encode_apng(frames, num_plays: num_plays)
end

private def solid_bitmap(w = 4, h = 4) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(1u8, 2u8, 3u8, 255u8) } }
end

# The Kitty transmit id (`i=<n>`) of an emit's control block.
private def kitty_id(encoded : String) : String?
  encoded[/i=(\d+)/, 1]
end

# --- Fix #4: Fire#decay clamp -------------------------------------------------

describe Crysterm::Widget::Effect::Fire do
  it "clamps an over-range constructor decay to 1.0" do
    s = headless_window
    f = Crysterm::Widget::Effect::Fire.new parent: s, width: 8, height: 8, decay: 2.0
    f.decay.should eq 1.0
  ensure
    s.try &.destroy
  end

  it "clamps a negative decay to 0.0 and keeps an in-range value" do
    s = headless_window
    f = Crysterm::Widget::Effect::Fire.new parent: s, width: 8, height: 8
    f.decay = -1.0
    f.decay.should eq 0.0
    f.decay = 0.9
    f.decay.should eq 0.9
    f.decay = 5.0
    f.decay.should eq 1.0
  ensure
    s.try &.destroy
  end
end

# --- Fix #2: finite animation holds the last frame ----------------------------

describe "Widget::Media::Base finite animation" do
  it "rests on the last frame (not frame 0) when a finite loop completes" do
    path = File.tempname("bugs3_finite", ".png")
    write_apng path, 3, 1 # 3 frames, play once
    begin
      s = headless_window
      img = Crysterm::Widget::Media::Sixel.new file: path, parent: s, width: 4, height: 3
      img.play
      # Let the compose fiber build frames and the frame clock run to the end of
      # the single play (3 frames * 20ms, plus compose latency).
      40.times { sleep 0.03.seconds }

      img.playing?.should be_false   # finite loop finished
      img.anim_index.should eq 3 - 1 # holds src.size - 1, not snapped to 0
    ensure
      img.try &.stop
      s.try &.destroy
    end
  ensure
    File.delete?(path) if path
  end
end

# --- Fix #1: Kitty buffer parity ---------------------------------------------

describe Crysterm::Widget::Media::Kitty do
  it "alternates double-buffer ids across emits even with anim_index pinned at 0" do
    s = headless_window
    k = Crysterm::Widget::Media::Kitty.new parent: s, width: 4, height: 3
    # A single-frame (bitmap-injected) source keeps anim_index at 0, mimicking a
    # streaming video: the OLD parity-by-anim_index logic would pick the same
    # buffer every time. The fix toggles per emit.
    bmp = solid_bitmap
    k.bitmap = bmp
    k.anim_index.should eq 0
    k.double_buffer?.should be_true

    # `#encode` no longer bakes the id in (it would be frozen by
    # `#payload_for`'s per-frame cache); the concrete id is chosen at *emit* time
    # by `#finalize_payload`. So finalize the SAME cached payload repeatedly —
    # exactly the cache-hit path a fixed-size loop hits after its first pass —
    # and the emitted buffer id must still alternate.
    cached = k.encode(bmp, 4, 4, 0, 0, 4, 3)
    id1 = kitty_id(k.finalize_payload(cached))
    id2 = kitty_id(k.finalize_payload(cached))
    id3 = kitty_id(k.finalize_payload(cached))
    id1.should_not be_nil
    id1.should_not eq id2    # alternates a -> b
    id2.should_not eq id3    # ...and b -> a
    id3.should eq id1        # back to the first buffer
    k.anim_index.should eq 0 # never advanced; parity is not derived from it
  ensure
    s.try &.destroy
  end

  it "reuses a single buffer id when double-buffering is off" do
    s = headless_window
    k = Crysterm::Widget::Media::Kitty.new parent: s, width: 4, height: 3, double_buffer: false
    bmp = solid_bitmap
    k.bitmap = bmp

    cached = k.encode(bmp, 4, 4, 0, 0, 4, 3)
    f1 = k.finalize_payload(cached)
    f2 = k.finalize_payload(cached)
    kitty_id(f1).should eq kitty_id(f2) # only @id_a used; no swap
    f1.should_not contain("{i}")        # placeholder fully substituted
  ensure
    s.try &.destroy
  end
end

# --- Fix #3: transition cancels before an early return ------------------------

describe "Widget CSS transition cancel-before-return" do
  it "stops an in-flight color tween when the new target equals the source" do
    s = headless_window 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "btn"
    # A long (2s) tween so it is comfortably still running when we re-apply.
    s.stylesheet = ".btn { background-color: #000000; transition: background-color 2.0s linear; } " \
                   ".btn:hover { background-color: #ffffff; }"
    s.repaint

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.15.seconds
    b.transition_running?.should be_true # tween is in flight toward white

    # Re-apply transitions with a snapshot whose bg equals the current style bg:
    # transition_color then hits `return if from == to`. With the fix, the stale
    # tween is cancelled first, so nothing keeps advancing.
    st = b.style
    prev = Crysterm::Widget::TransitionFrom.new(
      fg: st.fg, bg: st.bg, opacity: st.opacity, tint_alpha: st.tint_alpha)
    b.apply_style_transitions prev
    sleep 0.05.seconds

    b.transition_running?.should be_false # prior tween was cancelled, not left running
  ensure
    s.try &.destroy
  end
end
