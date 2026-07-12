require "./spec_helper"

include Crysterm

# Regression spec for BUGS15 #21 (src/widget_media_base.cr).
#
# `Media::Base#source` is called unconditionally on the render path. For a
# stream-mode video that is not currently open (e.g. after `#stop`, or before
# the first `#play`), it evaluated `VideoSource.mode(file).stream?` on every
# call. Under the default `media.video_decode = auto`, `mode` spawns a
# synchronous `ffprobe` subprocess to estimate the frame count — so a stopped,
# still-attached stream source ran an ffprobe per rendered frame indefinitely.
#
# Fix: memoize the resolved decode mode per loaded file (`@stream_mode`) so the
# render path re-probes at most once per file.
#
# This spec stubs `VideoSource.estimate_frames` (the ffprobe-spawning step) with
# a counting version that forces stream mode, making the count observable and
# ffmpeg-independent. Isolated in its own spec file so the stub can't leak.

module Crysterm
  class Widget
    module Media::VideoSource
      @@estimate_calls = 0

      def self.estimate_calls : Int32
        @@estimate_calls
      end

      def self.reset_estimate_calls : Nil
        @@estimate_calls = 0
      end

      # Overrides the real (ffprobe-spawning) estimator: count invocations and
      # return a large count so `auto` mode always resolves to Stream.
      def estimate_frames(file : String) : Int32?
        @@estimate_calls += 1
        100_000
      end
    end
  end
end

# Exposes the render-path `#source` call and the file-reset preamble.
private class ProbeAnsi < Crysterm::Widget::Media::Ansi
  def render_path_source
    source(open_stream: false)
  end

  def reload(file : String)
    reset_source_state file
  end
end

private def probe_window
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 12)
end

describe "BUGS15 #21 stream-mode source memoizes its decode mode" do
  it "resolves the mode (ffprobe) at most once across many render-path calls" do
    prev = Crysterm::Config.media_video_decode
    Crysterm::Config.media_video_decode = Crysterm::Widget::Media::VideoDecode::Auto
    s = probe_window
    img = ProbeAnsi.new(parent: s)
    img.file = "clip.mp4" # stream-mode video (via the stubbed estimator)

    Crysterm::Widget::Media::VideoSource.reset_estimate_calls

    # Render-path calls on an unopened stream source return nil without opening
    # ffmpeg; before the fix each one re-ran the mode probe (ffprobe).
    img.render_path_source.should be_nil
    img.render_path_source.should be_nil
    img.render_path_source.should be_nil
    Crysterm::Widget::Media::VideoSource.estimate_calls.should eq 1

    # A new file must re-resolve exactly once more.
    img.reload("other.mp4")
    img.render_path_source.should be_nil
    Crysterm::Widget::Media::VideoSource.estimate_calls.should eq 2
  ensure
    img.try &.stop
    s.try &.destroy
    Crysterm::Config.media_video_decode = prev if prev
  end
end
