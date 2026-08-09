require "./spec_helper"

include Crysterm

# An animation capture is a fixed-length filmstrip: `#feed_animation_frames`
# must emit exactly `duration * fps` frames, whatever the sampling did. The
# encoder holds every frame for `1/fps`, so the frame *count* is what sets
# playback speed — a scene too slow to render at `fps` (whose `FrameClock`
# then drops catch-up ticks) used to emit fewer frames than the recording
# lasted and play the clip back sped up: `tests/misc/themes.cr` recorded 5 s
# of app time into 25 frames, i.e. a 2.5 s clip running at 2×.
#
# Driven over an `IO::Memory` (no ffmpeg): every frame is the same fixed
# byte size, so `io.size / frame_size` is the frame count.

private def anim_frame_size(w : Window) : Int32
  Crysterm::Capture.rgba(
    Crysterm::Capture.render(w, 0, w.awidth, 0, w.aheight)).size
end

describe "Window#feed_animation_frames strip length" do
  it "emits exactly duration * fps frames for a fast-rendering scene" do
    w = headless_screen(20, 5)
    begin
      Widget::Box.new parent: w, left: 0, top: 0, width: 10, height: 3
      w.repaint
      io = IO::Memory.new
      fsize = anim_frame_size w

      w.feed_animation_frames(io, 0, w.awidth, 0, w.aheight, 0.5.seconds, 10)

      (io.size % fsize).should eq 0
      (io.size // fsize).should eq 5
    ensure
      w.destroy
    end
  end

  # The regression proper: a per-frame render slower than the frame period.
  # The sampler can only produce a fraction of the frames, and the missed
  # slots are filled by repeating the last frame it did produce — so the strip
  # still spans the full recording and plays back in real time.
  it "pads dropped slots so a slow scene still fills the strip" do
    w = headless_screen(20, 5)
    begin
      Widget::Box.new parent: w, left: 0, top: 0, width: 10, height: 3
      w.repaint
      fsize = anim_frame_size w

      # A sink that stalls every write well past the 1/20 s frame period, so
      # the clock falls behind and drops ticks exactly as a heavy scene does.
      slow = SlowAnimSink.new 0.08.seconds

      w.feed_animation_frames(slow, 0, w.awidth, 0, w.aheight, 0.5.seconds, 20)

      (slow.written % fsize).should eq 0
      (slow.written // fsize).should eq 10
    ensure
      w.destroy
    end
  end

  it "never emits an empty strip for a sub-frame-period duration" do
    w = headless_screen(6, 2)
    begin
      w.repaint
      io = IO::Memory.new
      fsize = anim_frame_size w

      # 0.05 s at 2 fps rounds to 0 slots; frame 0 always exists.
      w.feed_animation_frames(io, 0, w.awidth, 0, w.aheight, 0.05.seconds, 2)

      (io.size // fsize).should eq 1
    ensure
      w.destroy
    end
  end
end

# Counts bytes and sleeps on every write, standing in for an encoder fed by a
# scene that renders slower than the frame period.
private class SlowAnimSink < IO
  getter written = 0

  def initialize(@delay : Time::Span)
  end

  def write(slice : Bytes) : Nil
    @written += slice.size
    sleep @delay
  end

  def read(slice : Bytes)
    raise NotImplementedError.new("SlowAnimSink#read")
  end
end
