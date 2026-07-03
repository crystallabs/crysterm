require "./spec_helper"

include Crysterm

# Regression specs for BUGS-F1 findings owned by the media/terminal file set.
#
# Finding  2 — `TerminalEmulator#feed`/`split_incomplete_utf8` must NOT retain a
#   `Slice` *view* into the caller's reused read buffer for `@leftover`; it must
#   copy, or a multibyte char straddling a read boundary decodes to mojibake
#   once the reader fiber overwrites the buffer for its next read.
# Finding  3 — video streaming playback must carry a generation token so a
#   pause→play / stop→play doesn't leave two `stream_loop` fibers racing (double
#   speed, resurrected/leaked ffmpeg). Mirrors `Media::Tek#anim_gen`.
# Finding 19 — `Media::Tek` must not raise out of its `Rendered` hook on a bad
#   path/URL (that kills the render fiber); it degrades with a `decode_failed?`
#   flag, like `Media::Overlay`'s `@helper_failed`.
# Finding 40 — a failed `Terminal.spawn_window` must not leak its rendezvous
#   socket file (and must reap the launcher process).
# Finding 41 — `Media::Ueberzug` must reap a dead helper `Process` (not abandon a
#   zombie) and respawn/retry.

private def headless_window(w = 20, h = 5)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

private def default_attr : Int64
  Attr.pack(0_i64, -1, -1)
end

private def cell_char(em : TerminalEmulator, x : Int32, y : Int32) : Char
  em.lines[em.ybase + y][x].char
end

# --------------------------------------------------------------------------
# Finding 2: feed must not retain a view into the caller's reused buffer
# --------------------------------------------------------------------------

describe "TerminalEmulator#feed multibyte across a reused buffer (F1 #2)" do
  it "decodes a 3-byte char split across two feeds when the buffer is overwritten" do
    em = TerminalEmulator.new 20, 5, default_attr

    # '中' (U+4E2D) is E4 B8 AD. Replicate the widget's reader fiber exactly: one
    # `buf` reused across reads. First read delivers the incomplete lead E4 B8;
    # the emulator must stash a COPY, because the next read overwrites `buf`
    # before `feed` can prepend the held-back bytes.
    zh = "中".to_slice
    buf = Bytes.new 16
    buf[0] = zh[0] # E4
    buf[1] = zh[1] # B8
    em.feed buf[0, 2]

    # Next read reuses the same buffer: the trailing continuation byte lands at
    # buf[0], clobbering the very bytes a naive `@leftover` view pointed at.
    buf[0] = zh[2] # AD (overwrites E4)
    buf[1] = 0x00  # clobber the rest of the old view too, for good measure
    em.feed buf[0, 1]

    # With the copy fix the emulator reassembles E4 B8 AD -> '中'. With the old
    # view it would read the clobbered bytes and print U+FFFD (or wrong glyphs).
    cell_char(em, 0, 0).should eq '中'
  end

  it "handles an ASCII byte arriving right after the split multibyte lead" do
    em = TerminalEmulator.new 20, 5, default_attr
    star = "★".to_slice # E2 98 85
    buf = Bytes.new 16
    buf[0] = star[0]
    buf[1] = star[1]
    em.feed buf[0, 2] # incomplete
    buf[0] = star[2]  # 85, overwrites the viewed lead
    buf[1] = 'X'.ord.to_u8
    em.feed buf[0, 2] # completes '★', then a plain 'X'
    cell_char(em, 0, 0).should eq '★'
    cell_char(em, 1, 0).should eq 'X'
  end
end

# --------------------------------------------------------------------------
# Finding 3: streaming playback generation token
# --------------------------------------------------------------------------

describe "Media streaming generation token (F1 #3)" do
  # Structural, environment-independent: pause/stop must retire any running
  # stream loop by bumping the generation, and a captured generation must go
  # stale after such a call (exactly the condition `#stream_loop` exits on).
  it "bumps stream_gen on pause and stop so a captured generation goes stale" do
    s = headless_window
    img = Crysterm::Widget::Media::Ansi.new parent: s, top: 0, left: 0, width: 8, height: 4

    g0 = img.stream_gen
    captured = img.stream_gen # a loop fiber would capture this
    img.pause
    img.stream_gen.should be > g0
    (captured == img.stream_gen).should be_false # superseded: loop would exit

    g1 = img.stream_gen
    img.stop
    img.stream_gen.should be > g1
  ensure
    s.try &.destroy
  end

  it "advances the generation across pause->play->pause on a real stream" do
    have_ffmpeg = !Process.find_executable("ffmpeg").nil? &&
                  !Process.find_executable("ffprobe").nil?
    gif = "data/image/netscape.gif"
    pending! "ffmpeg/ffprobe not available" unless have_ffmpeg
    pending! "no video fixture" unless File.exists?(gif)

    tmp = File.tempfile("crysterm_vid", ".mp4")
    File.write(tmp.path, File.read(gif))
    prev = Crysterm::Config.media_video_decode
    Crysterm::Config.media_video_decode = Crysterm::Widget::Media::VideoDecode::Stream

    s = headless_window 80, 24
    img = Crysterm::Widget::Media::Ansi.new(
      file: tmp.path, parent: s, top: 0, left: 0, width: 8, height: 4)

    # Construction opened the stream and started playback, spawning one loop
    # under generation >= 1.
    img.playing?.should be_true
    gen_play1 = img.stream_gen
    gen_play1.should be > 0

    img.pause # retires the loop
    img.playing?.should be_false
    gen_pause = img.stream_gen
    gen_pause.should be > gen_play1

    img.play # spawns a fresh loop under a new generation
    img.playing?.should be_true
    img.stream_gen.should be > gen_pause
  ensure
    img.try &.stop
    s.try &.destroy
    Crysterm::Config.media_video_decode = prev if prev
    tmp.try &.delete rescue nil
  end
end

# --------------------------------------------------------------------------
# Finding 19: Media::Tek degrades on a bad source instead of crashing render
# --------------------------------------------------------------------------

describe "Media::Tek bad source graceful failure (F1 #19)" do
  it "does not raise out of draw_tek for a missing file; flags decode_failed" do
    s = headless_window
    tek = Crysterm::Widget::Media::Tek.new file: "/nonexistent/typo-#{Process.pid}.png", parent: s

    tek.decode_failed?.should be_false
    # `draw_tek` runs as the `Rendered` listener; it must swallow the decode
    # error rather than propagate it out of the render fiber.
    tek.draw_tek # must not raise
    tek.decode_failed?.should be_true
    tek.playing?.should be_false

    # A full window render (which fires the real `Rendered` hook) must also not
    # raise now that the flag short-circuits it.
    s._render
  ensure
    tek.try &.stop
    s.try &.destroy
  end

  it "does not raise for an unfetchable URL source" do
    s = headless_window
    tek = Crysterm::Widget::Media::Tek.new(
      file: "http://127.0.0.1:1/nope-#{Process.pid}.png", parent: s)
    tek.draw_tek # must not raise (fetch failure caught)
    tek.decode_failed?.should be_true
  ensure
    tek.try &.stop
    s.try &.destroy
  end

  it "clears decode_failed on load so a corrected source can retry" do
    s = headless_window
    tek = Crysterm::Widget::Media::Tek.new file: "/nonexistent/typo.png", parent: s
    tek.draw_tek
    tek.decode_failed?.should be_true
    tek.load "/still/missing.png" # new source: retry allowed
    tek.decode_failed?.should be_false
  ensure
    tek.try &.stop
    s.try &.destroy
  end
end

# --------------------------------------------------------------------------
# Finding 40: failed spawn_window must not leak its rendezvous socket
# --------------------------------------------------------------------------

describe "Terminal.spawn_window failure cleanup (F1 #40)" do
  it "deletes the rendezvous socket when the launcher fails to spawn" do
    dir = Crysterm::Config.environment_xdg_runtime_dir || Dir.tempdir
    pattern = File.join(dir, "crysterm-win-#{Process.pid}-*.sock")
    before = Dir.glob(pattern)

    # A launcher whose argv points at a binary that does not exist, so
    # `Process.new` raises immediately inside `spawn_window`'s begin/ensure.
    bad = Crysterm::Terminal::Launcher.new(
      "crysterm-nonexistent-#{Process.pid}",
      ->(inner : Array(String), _c : Int32, _r : Int32, _t : String?) do
        ["crysterm-nonexistent-binary-#{Process.pid}"] + inner
      end)

    expect_raises(Exception) do
      Crysterm::Terminal.spawn_window(launcher: bad, cols: 80, rows: 24)
    end

    after = Dir.glob(pattern)
    # No new stale socket file should remain from the failed spawn.
    (after - before).should be_empty
  end
end

# --------------------------------------------------------------------------
# Finding 41: Ueberzug helper-process reaping
# --------------------------------------------------------------------------

describe "Media::Ueberzug helper reaping (F1 #41)" do
  # Full zombie-reap exercise needs the `ueberzug` binary (not installed in CI);
  # here we assert the non-crashing behaviour that the reap path guards: a
  # `send`/`remove` with no helper available is a safe no-op and never raises out
  # of the render hook.
  it "does not raise when no helper binary is available" do
    pending! "ueberzug present; skip the no-binary path" if Crysterm::Widget::Media::Ueberzug.binary
    s = headless_window
    uz = Crysterm::Widget::Media::Ueberzug.new(
      file: "/nonexistent/pic-#{Process.pid}.png", parent: s, width: 8, height: 4)
    # A render fires the `Rendered` hook -> redraw_image -> send; with no helper
    # `Ueberzug.proc` returns nil and `send` returns early without raising.
    s._render
    uz.stop rescue nil
  ensure
    s.try &.destroy
  end
end
