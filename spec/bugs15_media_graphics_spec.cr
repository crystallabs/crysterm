require "./spec_helper"

include Crysterm

# Regression specs for the BUGS15 media-graphics findings:
#
# * #23 — `Media::Graphics#raw_bytes` latches a failed read (`@raw_failed`), so a
#   broken iTerm source (unreachable URL, deleted file) is not re-fetched
#   (curl/wget/File.read) on every rendered frame. Cleared by `#load`/`#clear_image`.
# * #24 — `Media::Graphics#redraw_image` erases a Kitty graphic slid to a negative
#   origin (undrawable `#content_rect`) instead of leaving it floating and
#   re-invalidating the stale cell rect every frame.
# * #14 — `Media::Kitty#z=`/`#background=` at runtime drop the payload cache and
#   request a render, so the new stacking layer actually takes effect.
# * #15 — `Media::Kitty#target_pixels` skips the source-resolution cap for
#   `Fit::None` (its native-1:1 placement is not invariant under a box reduction).
# * #52 — `Media::Graphics#double_buffer=` drops the payload cache (no stale
#   `{o}` literal / single-buffer replay of a double-buffered payload); the Kitty
#   override deletes the now-unused `@id_b` placement on true→false.
# * #53 — a payload-cache drop (`reset_payload_cache`, reached from `#fit=` /
#   `double_buffer=` / `z=`) no longer re-arms `@anim_checked`, so a stopped
#   animation/video is not silently resumed by the first-paint auto-play probe.
#   Only `#load`/`#clear_image` re-arm it.

private def gfx_window(w = 40, h = 12, output = IO::Memory.new)
  Crysterm::Window.new(input: IO::Memory.new, output: output,
    error: IO::Memory.new, width: w, height: h)
end

private def solid_bmp(v = 5u8, w = 4, h = 4) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(v, v, v, 255u8) } }
end

# Exposes `Media::Graphics#raw_bytes` and the failure latch for #23.
private class RawProbe < Crysterm::Widget::Media::Iterm
  def probe_raw_bytes
    raw_bytes
  end

  def probe_raw_failed
    @raw_failed
  end

  def probe_set_file(f : String)
    @file = f
  end
end

# Exposes the private paint/cache/anim state and counts terminal deletes.
private class KittyProbe < Crysterm::Widget::Media::Kitty
  getter cleared_count = 0

  def probe_last_drawn
    @last_drawn
  end

  def probe_payload_geom
    @payload_geom
  end

  def probe_frame_payloads
    @frame_payloads
  end

  def probe_emitted_key
    @emitted_key
  end

  def probe_anim_checked
    @anim_checked
  end

  def probe_id_b
    @id_b
  end

  protected def graphic_cleared(s : ::Crysterm::Window)
    @cleared_count += 1
    super
  end
end

describe "BUGS15 #23: raw_bytes latches failure" do
  it "returns nil on a failed read, latches, and does not retry until reset" do
    s = gfx_window
    img = RawProbe.new parent: s, top: 0, left: 0, width: 8, height: 4
    img.probe_set_file "/nonexistent/bugs15-raw-latch.png"

    # First read fails and latches.
    img.probe_raw_bytes.should be_nil
    img.probe_raw_failed.should be_true

    # With the latch set, even pointing at a now-valid file must NOT re-attempt
    # the read (that is the per-frame curl/wget/File.read churn the latch kills).
    img.probe_set_file "data/image/matterhorn.png"
    img.probe_raw_bytes.should be_nil
  ensure
    s.try &.destroy
  end

  it "clears the latch on #load so a corrected source is retried" do
    s = gfx_window
    img = RawProbe.new parent: s, top: 0, left: 0, width: 8, height: 4
    img.probe_set_file "/nonexistent/bugs15-raw-reload.png"
    img.probe_raw_bytes.should be_nil
    img.probe_raw_failed.should be_true

    img.load "data/image/matterhorn.png"
    img.probe_raw_failed.should be_false
    img.probe_raw_bytes.should_not be_nil
  ensure
    s.try &.destroy
  end

  it "clears the latch on #clear_image" do
    s = gfx_window
    img = RawProbe.new parent: s, top: 0, left: 0, width: 8, height: 4
    img.probe_set_file "/nonexistent/bugs15-raw-clear.png"
    img.probe_raw_bytes.should be_nil
    img.probe_raw_failed.should be_true

    img.clear_image
    img.probe_raw_failed.should be_false
  ensure
    s.try &.destroy
  end
end

describe "BUGS15 #24: Kitty graphic deleted when slid to a negative origin" do
  it "erases the graphic and stops re-invalidating once it pokes offscreen" do
    s = gfx_window
    img = KittyProbe.new parent: s, top: 1, left: 0, width: 4, height: 3
    img.bitmap = solid_bmp

    s._render
    img.probe_last_drawn.should_not be_nil # placed on screen
    img.cleared_count.should eq 0

    # Slide it above the top edge: content_rect is now nil (negative origin).
    img.top = -2
    s._render

    # Pre-fix: redraw_image bailed on `content_rect || return` without clearing,
    # leaving the Kitty layer floating and @last_drawn stuck at the old rect.
    img.cleared_count.should be >= 1   # Kitty a=d delete issued
    img.probe_last_drawn.should be_nil # erased and no longer re-invalidated
  ensure
    s.try &.destroy
  end
end

describe "BUGS15 #14: Kitty z=/background= take effect at runtime" do
  it "bakes z= into the encoded payload" do
    s = gfx_window
    k = Crysterm::Widget::Media::Kitty.new parent: s, top: 0, left: 0, width: 4, height: 3
    bmp = solid_bmp
    k.bitmap = bmp

    k.encode(bmp, 4, 4, 0, 0, 4, 3).should_not contain(",z=")
    k.z = -1
    k.z.should eq -1
    k.encode(bmp, 4, 4, 0, 0, 4, 3).should contain(",z=-1")
  ensure
    s.try &.destroy
  end

  it "drops the payload cache and emit key on a real z change" do
    s = gfx_window
    k = KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    k.bitmap = solid_bmp
    s._render

    k.probe_payload_geom.should_not be_nil
    k.probe_emitted_key.should_not be_nil

    k.z = -5
    k.probe_payload_geom.should be_nil
    k.probe_frame_payloads.empty?.should be_true
    k.probe_emitted_key.should be_nil
  ensure
    s.try &.destroy
  end

  it "leaves the cache intact on a no-op z assignment" do
    s = gfx_window
    k = KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    k.bitmap = solid_bmp
    s._render
    k.probe_payload_geom.should_not be_nil

    k.z = nil # already nil — must not churn the cache
    k.probe_payload_geom.should_not be_nil
  ensure
    s.try &.destroy
  end

  it "routes background= through z= (cache drop + z state)" do
    s = gfx_window
    k = KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    k.bitmap = solid_bmp
    s._render
    k.probe_payload_geom.should_not be_nil

    k.background = true
    k.z.should eq -1
    k.background?.should be_true
    k.probe_payload_geom.should be_nil # re-emit forced
  ensure
    s.try &.destroy
  end
end

describe "BUGS15 #15: Kitty source-resolution cap skipped for Fit::None" do
  it "keeps the full box for Fit::None (native 1:1 survives c=/r=)" do
    s = gfx_window
    src = solid_bmp(9u8, 200, 200)
    k = Crysterm::Widget::Media::Kitty.new parent: s, top: 0, left: 0,
      width: 80, height: 20, cell_pixel_width: 10, cell_pixel_height: 20,
      fit: Widget::Media::Fit::None
    k.bitmap = src
    # 80*10 x 20*20 = 800x400; uncapped despite the 200x200 source.
    k.target_pixels(80, 20).should eq({800, 400})
  ensure
    s.try &.destroy
  end

  it "still caps to the source for the aspect-preserving fits (Stretch)" do
    s = gfx_window
    src = solid_bmp(9u8, 200, 200)
    k = Crysterm::Widget::Media::Kitty.new parent: s, top: 0, left: 0,
      width: 80, height: 20, cell_pixel_width: 10, cell_pixel_height: 20,
      fit: Widget::Media::Fit::Stretch
    k.bitmap = src
    # long_box 800 > long_src 200 → scale 0.25 → 200x100.
    k.target_pixels(80, 20).should eq({200, 100})
  ensure
    s.try &.destroy
  end
end

describe "BUGS15 #52: toggling double_buffer drops the cache and clears the ghost" do
  it "drops the payload cache on toggle and deletes the unused @id_b placement" do
    outbuf = IO::Memory.new
    s = gfx_window(output: outbuf)
    k = KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    k.double_buffer?.should be_true
    k.bitmap = solid_bmp
    s._render
    k.probe_payload_geom.should_not be_nil

    idb = k.probe_id_b
    outbuf.clear
    k.double_buffer = false

    k.double_buffer?.should be_false
    # Cache dropped → no stale double-buffered payload (literal {o}) replayed.
    k.probe_payload_geom.should be_nil
    k.probe_frame_payloads.empty?.should be_true
    k.probe_emitted_key.should be_nil
    # The now-unused second buffer is explicitly deleted so no frozen ghost.
    outbuf.to_s.should contain("a=d,d=i,i=#{idb},q=2")
  ensure
    s.try &.destroy
  end

  it "false→true just drops the cache (no terminal delete needed)" do
    outbuf = IO::Memory.new
    s = gfx_window(output: outbuf)
    k = KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3,
      double_buffer: false
    k.bitmap = solid_bmp
    s._render
    k.probe_payload_geom.should_not be_nil

    outbuf.clear
    k.double_buffer = true
    k.double_buffer?.should be_true
    k.probe_payload_geom.should be_nil # cache dropped so frames re-encode with the swap suffix
  ensure
    s.try &.destroy
  end
end

describe "BUGS15 #53: cache drops do not re-arm first-paint auto-play" do
  it "keeps @anim_checked latched across fit=/double_buffer=/z=" do
    s = gfx_window
    k = KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    k.bitmap = solid_bmp
    s._render
    k.probe_anim_checked.should be_true # first paint probed the source

    k.fit = Widget::Media::Fit::Contain
    k.probe_anim_checked.should be_true # NOT re-armed (would re-open a stopped video)

    k.double_buffer = false
    k.probe_anim_checked.should be_true

    k.z = -1
    k.probe_anim_checked.should be_true
  ensure
    s.try &.destroy
  end

  it "re-arms @anim_checked only on #load and #clear_image" do
    s = gfx_window
    k = KittyProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    k.bitmap = solid_bmp
    s._render
    k.probe_anim_checked.should be_true

    k.load "data/image/matterhorn.png"
    k.probe_anim_checked.should be_false # load re-arms

    s._render
    k.probe_anim_checked.should be_true
    k.clear_image
    k.probe_anim_checked.should be_false # clear_image re-arms
  ensure
    s.try &.destroy
  end
end
