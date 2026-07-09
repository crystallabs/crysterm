require "./spec_helper"
require "file_utils"

include Crysterm

# Regression spec for BUGS12 #25: shared-clock streaming video — `stop` racing
# `Stream#restart` leaked a relaunched ffmpeg.
#
# `Stream#restart` has fiber yield points (`close` → `pr.wait`, `launch`, the
# first-frame read). If `stop` runs in that window it sets `@stream = nil` and
# calls `st.close` — a no-op, since restart's own `close` already nil'd
# `@process`. Restart then resumed and did `@process = launch`, spawning a new
# ffmpeg on an object nothing owned: never terminated or reaped, blocked
# forever once its stdout pipe filled. The self-paced `#stream_loop` defended
# this with a post-loop ownership check, and `#advance_stream` checked
# ownership *before* restart — but nothing re-checked *after* it.
#
# Fix: `#advance_stream` re-checks `stream.same?(@stream)` after `restart`
# returns, closing the disowned stream (reaping the relaunched ffmpeg) and
# returning false — without latching `@load_failed` for a failure that the
# disowning itself caused. `#tick_frame` correspondingly ends playback only
# for a stream it still owns, so a stop→play landing mid-restart isn't
# clobbered by the stale tick.
#
# The interleaving is forced deterministically: a spec-local `Stream` subclass
# overrides the private `#launch` to run a hook — i.e. exactly between
# restart's `close` (which nils `@process`) and the relaunch, the reported
# window. "ffmpeg" itself is a fake shell script on PATH that records its pid,
# emits one 2×2 RGBA frame, closes stdout (EOF for the reader) and lingers, so
# no real ffmpeg/ffprobe is needed and orphans are observable via the pids.

private FRAME_BYTES = 2 * 2 * 4

private class HookStream < Crysterm::Widget::Media::VideoSource::Stream
  # Runs inside `#restart`, after its `close` nil'd `@process` and before the
  # relaunch — the exact yield window of the reported race. (Also technically
  # runs during `initialize`'s launch, where it is still nil.)
  property before_launch : Proc(Nil)? = nil

  private def launch : Process
    @before_launch.try &.call
    super
  end
end

private class RaceProbe < Crysterm::Widget::Media::Ansi
  def advance!(st) : Bool
    advance_stream st
  end

  def stream_ref : Crysterm::Widget::Media::VideoSource::Stream?
    @stream
  end

  def set_stream(st : Crysterm::Widget::Media::VideoSource::Stream?)
    @stream = st
  end

  def force_playing(v : Bool)
    @playing = v
  end

  def load_failed? : Bool
    @load_failed
  end
end

private def headless_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

# Installs a fake `ffmpeg` (first on PATH) that appends its pid to a file,
# writes one frame and closes stdout, then lingers; yields
# `{pid_file, empty_flag}` — touching *empty_flag* makes subsequent launches
# exit frameless (a failed restart). Restores PATH/env afterwards.
private def with_fake_ffmpeg(&)
  dir = File.tempname("crysterm_fake_ffmpeg")
  Dir.mkdir_p dir
  pid_file = File.join(dir, "pids")
  empty_flag = File.join(dir, "no_frames")
  File.write File.join(dir, "ffmpeg"), <<-SH
    #!/bin/sh
    echo $$ >> "$CRYSTERM_FAKE_PIDS"
    if [ -e "$CRYSTERM_FAKE_EMPTY" ]; then
      exit 0
    fi
    head -c #{FRAME_BYTES} /dev/zero
    exec >&-
    exec sleep 5
    SH
  File.chmod File.join(dir, "ffmpeg"), 0o755
  File.write pid_file, ""
  old_path = ENV["PATH"]?
  ENV["PATH"] = "#{dir}:#{old_path}"
  ENV["CRYSTERM_FAKE_PIDS"] = pid_file
  ENV["CRYSTERM_FAKE_EMPTY"] = empty_flag
  yield pid_file, empty_flag
ensure
  ENV["PATH"] = old_path if old_path
  ENV.delete "CRYSTERM_FAKE_PIDS"
  ENV.delete "CRYSTERM_FAKE_EMPTY"
  # Reap any fake still lingering so a failing run doesn't strand sleeps.
  if pid_file && File.exists?(pid_file)
    File.read_lines(pid_file).each do |line|
      if pid = line.to_i64?
        Process.signal(Signal::KILL, pid) rescue nil
      end
    end
  end
  FileUtils.rm_rf dir if dir
end

private def read_pids(pid_file) : Array(Int64)
  File.read_lines(pid_file).compact_map(&.to_i64?)
end

describe "Media::Base streaming restart vs stop race (BUGS12 #25)" do
  it "reaps the relaunched ffmpeg when stop disowns the stream mid-restart" do
    with_fake_ffmpeg do |pid_file, _empty|
      s = headless_screen
      begin
        probe = RaceProbe.new(parent: s, top: 0, left: 0, width: 8, height: 4)
        st = HookStream.new("dummy.mp4", 2, 2, 10.0)
        probe.set_stream st
        probe.force_playing true
        # Fires inside `restart`, after its `close` and before the relaunch —
        # the reported window, where stop's own `st.close` finds no process.
        st.before_launch = -> { probe.stop; nil }

        probe.advance!(st).should be_true  # consumes the pre-read first frame
        probe.advance!(st).should be_false # EOF → restart, disowned mid-flight

        probe.stream_ref.should be_nil
        probe.playing?.should be_false
        # The disowned-restart failure must not latch a permanent load failure.
        probe.load_failed?.should be_false

        pids = read_pids(pid_file)
        pids.size.should eq 2 # initial launch + restart's relaunch
        # Both ffmpegs terminated AND reaped — the relaunched one was the leak.
        pids.each { |pid| Process.exists?(pid).should be_false }
      ensure
        s.destroy
      end
    end
  end

  it "closes only the disowned stream when a new stream replaced it mid-restart" do
    with_fake_ffmpeg do |pid_file, _empty|
      s = headless_screen
      st2 = nil
      begin
        probe = RaceProbe.new(parent: s, top: 0, left: 0, width: 8, height: 4)
        st = HookStream.new("dummy.mp4", 2, 2, 10.0)   # pid 1
        st2 = HookStream.new("dummy2.mp4", 2, 2, 10.0) # pid 2
        probe.set_stream st
        probe.force_playing true
        st.before_launch = -> { probe.set_stream st2; nil }

        probe.advance!(st).should be_true
        probe.advance!(st).should be_false # relaunch (pid 3) closed, not adopted

        probe.stream_ref.try(&.same?(st2)).should be_true

        pids = read_pids(pid_file)
        pids.size.should eq 3
        Process.exists?(pids[0]).should be_false # st's first ffmpeg
        Process.exists?(pids[2]).should be_false # st's relaunched ffmpeg
        Process.exists?(pids[1]).should be_true  # the replacement, untouched
      ensure
        st2.try &.close
        s.destroy
      end
    end
  end

  it "does not latch load_failed when a disowned restart also fails" do
    with_fake_ffmpeg do |pid_file, empty_flag|
      s = headless_screen
      begin
        probe = RaceProbe.new(parent: s, top: 0, left: 0, width: 8, height: 4)
        st = HookStream.new("dummy.mp4", 2, 2, 10.0)
        probe.set_stream st
        probe.force_playing true
        st.before_launch = -> {
          probe.stop
          File.touch empty_flag # the relaunched fake now emits no frames
          nil
        }

        probe.advance!(st).should be_true
        probe.advance!(st).should be_false

        probe.load_failed?.should be_false # failure was the disowning's doing
        pids = read_pids(pid_file)
        pids.size.should eq 2
        pids.each { |pid| Process.exists?(pid).should be_false }
      ensure
        s.destroy
      end
    end
  end
end
