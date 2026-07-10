require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 "Widget top-level" media findings:
#
# * W5 — `Media::Base#source` must not open a *streaming* video decoder from
#   render paths: only explicit entry points (`#play`, backend `#load`) pass
#   `open_stream: true`. Otherwise a `#stop` was undone by the very next
#   render, which relaunched ffmpeg on the render fiber (blocked forever).
# * W7 — `#play`'s frame-composite fiber checks the source is still current
#   before committing `@src_frames`/playback (a `load`/`bitmap=` during the
#   composite otherwise had its state clobbered by the stale fiber).
# * W9 — `Media::RenderHook` migrates its `Rendered` listener across windows
#   (teardown on Detach, re-register on Attach/Reparent), mirroring the
#   BUGS12#26 fix for `Media::ScreenOverlay`.
# * W10 — `Media::Graphics#content_rect` returns nil for a partially-offscreen
#   widget (negative origin), so `#redraw_image` never emits a clamped
#   (`\e[0;…H`) or malformed (`\e[-1;…H`) CUP and `@last_drawn` never records
#   a negative rect for the erase pass to mistarget.

private def media_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 40, height: 12)
end

private def solid_bitmap(r = 10, g = 20, b = 30, w = 4, h = 4) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(r, g, b, 255) } }
end

# Exposes the protected `#source` and the stream/failure latches for W5.
private class SourceProbe < Crysterm::Widget::Media::Ansi
  def probe_set_file(f : String)
    @file = f
  end

  def probe_source(open_stream : Bool = false)
    source(open_stream: open_stream)
  end

  def probe_load_failed
    @load_failed
  end

  def probe_stream
    @stream
  end
end

# Minimal RenderHook consumer for W9 (Ueberzug/Tek both need external
# helpers, so the module contract is exercised directly).
private class HookProbe < Crysterm::Widget::Box
  include Crysterm::Widget::Media::RenderHook

  getter paints = 0

  def initialize(**box)
    super(**box)
    register_render_hook_deferred { @paints += 1 }
  end

  def hooked_screen
    @listener_screen
  end
end

# Exposes the private `#content_rect` for W10.
private class RectProbe < Crysterm::Widget::Media::Sixel
  def probe_content_rect
    content_rect
  end
end

describe "BUGS13 W5: streaming decoder only opens on explicit request" do
  it "render-path source() returns nil for an unopened stream-mode video without latching failure" do
    orig = Crysterm::Config.media_video_decode
    Crysterm::Config.media_video_decode = Crysterm::Widget::Media::VideoDecode::Stream
    begin
      s = media_screen
      img = SourceProbe.new parent: s, top: 0, left: 0, width: 8, height: 4
      img.probe_set_file "/nonexistent/bugs13-w5-clip.mp4"

      # The unconditional render-fiber call (`Media::Cells#render`) — must not
      # attempt the open (no ffprobe/ffmpeg launch), and must NOT latch
      # `@load_failed` (a later explicit play must still be able to open).
      img.probe_source.should be_nil
      img.probe_load_failed.should be_false
      img.probe_stream.should be_nil

      # A full window render goes through the same path.
      s._render
      img.probe_load_failed.should be_false
      img.probe_stream.should be_nil

      # The explicit entry point attempts the open (and fails here — the file
      # doesn't exist — latching the failure so renders don't retry).
      img.probe_source(open_stream: true).should be_nil
      img.probe_load_failed.should be_true
    ensure
      Crysterm::Config.media_video_decode = orig
      s.try &.destroy
    end
  end

  it "an eager (non-stream) source still decodes from the render path" do
    s = media_screen
    img = SourceProbe.new parent: s, top: 0, left: 0, width: 8, height: 4
    img.probe_set_file "#{__DIR__}/../data/image/matterhorn.png"
    img.probe_source.should_not be_nil
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 W7: stale composite fiber does not clobber a newer source" do
  it "a bitmap= during the composite keeps the new source's state" do
    gif = "#{__DIR__}/../data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)
    s = media_screen
    img = Crysterm::Widget::Media::Sixel.new file: gif, parent: s
    img.play
    img.playing?.should be_true

    # Supersede the source while the composite fiber is still building the
    # GIF's frames. The stale fiber must not commit them afterwards.
    img.bitmap = solid_bitmap
    img.playing?.should be_false
    img.frames_ready?.should be_false

    # Give the stale fiber ample time to finish compositing; its commit must
    # have been rejected (source no longer current).
    10.times do
      sleep 50.milliseconds
      break if img.frames_ready?
    end
    img.frames_ready?.should be_false
    img.playing?.should be_false
    img.anim_index.should eq 0
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "an undisturbed play still commits its frames" do
    gif = "#{__DIR__}/../data/image/netscape.gif"
    pending! "no animated test fixture" unless File.exists?(gif)
    s = media_screen
    img = Crysterm::Widget::Media::Sixel.new file: gif, parent: s
    img.play
    50.times do
      break if img.frames_ready?
      sleep 20.milliseconds
    end
    img.frames_ready?.should be_true
    img.playing?.should be_true
  ensure
    img.try &.stop
    s.try &.destroy
  end
end

describe "BUGS13 W9: Media::RenderHook migrates across windows" do
  it "re-registers on the new window and drops the old one (constructed attached)" do
    s1 = media_screen
    s2 = media_screen
    a = Widget::Box.new parent: s1, width: "100%", height: "100%"
    b = Widget::Box.new parent: s2, width: "100%", height: "100%"

    probe = HookProbe.new parent: a, top: 0, left: 0, width: 4, height: 2
    probe.hooked_screen.should eq s1

    s1._render
    probe.paints.should eq 1

    b.append probe # cross-window move: Detach(s1) then Attach(s2)
    probe.hooked_screen.should eq s2

    # The old window no longer drives the paint block...
    s1._render
    probe.paints.should eq 1
    # ...the new one does, exactly once per render (no duplicate listeners).
    s2._render
    probe.paints.should eq 2
  ensure
    s1.try &.destroy
    s2.try &.destroy
  end

  it "retains the paint block across repeated moves (not a fire-once slot)" do
    s1 = media_screen
    s2 = media_screen
    probe = HookProbe.new top: 0, left: 0, width: 4, height: 2

    a = Widget::Box.new parent: s1, width: "100%", height: "100%"
    a.append probe
    probe.hooked_screen.should eq s1
    s1._render
    probe.paints.should eq 1

    # Second migration must work too (the deferred block is retained, not
    # a fire-once slot).
    b = Widget::Box.new parent: s2, width: "100%", height: "100%"
    b.append probe
    probe.hooked_screen.should eq s2
    s1._render
    probe.paints.should eq 1
    s2._render
    probe.paints.should eq 2
  ensure
    s1.try &.destroy
    s2.try &.destroy
  end

  it "keeps a single registration across a same-window reparent" do
    s = media_screen
    a = Widget::Box.new parent: s, width: "100%", height: "100%"
    b = Widget::Box.new parent: s, width: "100%", height: "100%"
    probe = HookProbe.new parent: a, top: 0, left: 0, width: 4, height: 2

    b.append probe # same-window move: Reparent only
    probe.hooked_screen.should eq s

    s._render
    probe.paints.should eq 1 # exactly one listener
  ensure
    s.try &.destroy
  end

  it "teardown_render_hook on destroy leaves nothing firing" do
    s = media_screen
    probe = HookProbe.new parent: s, top: 0, left: 0, width: 4, height: 2
    s._render
    probe.paints.should eq 1
    probe.destroy
    s._render
    probe.paints.should eq 1
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 W10: graphics overlay geometry for a partially-offscreen widget" do
  it "content_rect is nil when the widget pokes above the screen" do
    s = media_screen
    img = RectProbe.new parent: s, top: -2, left: 0, width: 8, height: 6
    img.bitmap = solid_bitmap
    s._render
    # yi would be -2 — not drawable; the paint/erase lifecycle must treat it
    # like a hidden widget instead of emitting `\e[-1;…H`.
    img.probe_content_rect.should be_nil
  ensure
    s.try &.destroy
  end

  it "content_rect is nil for the one-row-off (yi == -1) clamped case too" do
    s = media_screen
    img = RectProbe.new parent: s, top: -1, left: 0, width: 8, height: 6
    img.bitmap = solid_bitmap
    s._render
    img.probe_content_rect.should be_nil # pre-fix this emitted `\e[0;…H`
  ensure
    s.try &.destroy
  end

  it "content_rect is nil when the widget pokes off the left edge" do
    s = media_screen
    img = RectProbe.new parent: s, top: 1, left: -3, width: 8, height: 6
    img.bitmap = solid_bitmap
    s._render
    img.probe_content_rect.should be_nil
  ensure
    s.try &.destroy
  end

  it "a render with offscreen graphics emits no malformed or clamped CUP" do
    outbuf = IO::Memory.new
    s = Crysterm::Window.new(input: IO::Memory.new, output: outbuf,
      error: IO::Memory.new, width: 40, height: 12)
    [{-2, 0}, {-1, 0}, {1, -3}].each do |(top, left)|
      img = RectProbe.new parent: s, top: top, left: left, width: 8, height: 6
      img.bitmap = solid_bitmap
    end
    s._render
    str = outbuf.to_s
    str.should_not match(/\e\[-/)      # negative CSI parameter (malformed)
    str.should_not match(/\e\[0;\d+H/) # zero row: one row off, unclipped
    str.should_not match(/\e\[\d+;0H/) # zero column, ditto
  ensure
    s.try &.destroy
  end

  it "a fully on-screen graphic still reports its content rect" do
    s = media_screen
    img = RectProbe.new parent: s, top: 1, left: 2, width: 4, height: 3
    img.bitmap = solid_bitmap
    s._render
    img.probe_content_rect.should eq({2, 1, 4, 3})
  ensure
    s.try &.destroy
  end
end
