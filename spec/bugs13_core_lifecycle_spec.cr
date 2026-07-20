require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 core findings C11, C20
# (src/window_capture.cr, src/crysterm.cr):
#
# C11 — animated capture samples the CURRENT buffer on a wall-clock `1/fps`
#       grid (a `FrameClock` ticker) instead of writing one frame per
#       `Rendered` event into a fixed `-framerate` stream, so clip length
#       tracks `duration` rather than `frames/fps`. (The first-write-before-
#       clock.start ordering and the absence of the `Event::Rendered` scheme
#       are already pinned by spec/bugs5_lifecycle_spec.cr.)
# C20 — SIGTSTP/SIGCONT suspend-resume is wired: TSTP hands the terminal(s)
#       back and STOPs the process; CONT resumes, then reallocs (invalidating
#       `@flushed_lines`) and repaints so shell output can't persist as corruption.

private def b13l_window(w = 20, h = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def b13l_wait_until(timeout = 2.seconds, &)
  deadline = Time.instant + timeout
  until yield
    raise "wait_until: condition not met within #{timeout}" if Time.instant > deadline
    sleep 2.milliseconds
  end
end

describe "BUGS13 C11: animated capture samples on a wall-clock 1/fps grid" do
  it "accumulates frames over the duration with zero renders happening" do
    w = b13l_window 6, 2
    begin
      io = IO::Memory.new
      # One frame's RGBA payload, to delimit frames in the accumulated stream.
      fsize = Crysterm::Capture.rgba(
        Crysterm::Capture.render(w, 0, w.awidth, 0, w.aheight)).size
      fsize.should be > 0

      # No ffmpeg needed: `feed_animation_frames` is the sampling half, fed an
      # in-memory sink. NOTHING renders during the window — the pre-fix
      # per-`Rendered` scheme would have produced only the initial frame
      # (a 0.1 s clip out of a 0.35 s capture).
      w.feed_animation_frames(io, 0, w.awidth, 0, w.aheight, 0.35.seconds, 10)

      (io.size % fsize).should eq 0
      frames = io.size // fsize
      # First frame + one per FrameClock tick (0.1 s at fps 10): nominally 4.
      # The clock drops (never bursts) frames under load, so accept a lag, but
      # require genuine wall-clock accumulation and the duration/fps bound.
      frames.should be >= 2
      frames.should be <= 6
    ensure
      w.destroy
    end
  end
end

describe "BUGS13 C20: SIGTSTP/SIGCONT suspend-resume" do
  # Actually raising SIGTSTP/SIGSTOP would suspend the spec process itself,
  # so the trap installation is asserted structurally (like
  # spec/bugs5_lifecycle_spec.cr does for the capture pipeline); the resume
  # half (`Crysterm.resume_terminals`) is exercised for real below.
  it "wires the TSTP trap to suspend_terminals + STOP, and CONT to resume_terminals" do
    src = File.read(File.join(__DIR__, "..", "src", "crysterm.cr"))

    tstp = src.index!("Signal::TSTP.trap")
    tstp_body = src[tstp, 200]
    tstp_body.includes?("suspend_terminals").should be_true
    tstp_body.includes?("Process.signal Signal::STOP").should be_true

    cont = src.index!("Signal::CONT.trap")
    src[cont, 120].includes?("resume_terminals").should be_true
  end

  it "resume_terminals reallocs and repaints, so the post-suspend frame is re-emitted" do
    w = b13l_window 30, 5
    begin
      Widget::Box.new parent: w, left: 0, top: 0, width: 12, height: 1, content: "SUSPEND20"
      w.repaint
      out = w.output.as(IO::Memory)

      # Suspend: the terminal is handed back (teardown sequences, continuation
      # stored). Headless-safe — a non-tty just skips the mode changes.
      Crysterm.suspend_terminals
      out.clear

      # The draw diff runs against `@flushed_lines`, which still claims the terminal
      # shows the pre-suspend frame; without the realloc a resume would emit
      # nothing and any shell output would persist as corruption.
      Crysterm.resume_terminals
      b13l_wait_until { out.to_s.includes? "SUSPEND20" }
    ensure
      w.destroy
    end
  end
end
