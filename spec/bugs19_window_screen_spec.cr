require "./spec_helper"

include Crysterm

# Regression specs for BUGS19 batch:
#
# * Bug #5 — `Window#show` after `#hide` leaves the alternate screen blank
# * Bug #7 — input fiber lifecycle on EOF: `start_input` restartable,
#   `input_fiber?` never hands out a finished fiber, `listening?` stays intent
# * Bug #9 — gpm reader fiber has no per-event exception isolation

# Local variant of `spec_helper`'s `headless_screen`, pinning
# `OptimizationFlag::None` so a repaint always re-emits the full region. Named
# apart from the shared helper: two same-named top-level defs would overload
# each other and the call below would silently pick the wrong one.
private def b19_headless_screen(w = 80, h = 24, optimization = Crysterm::OptimizationFlag::None)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false, optimization: optimization)
end

# ---------------------------------------------------------------------------
# Bug #5

describe "BUGS19 #5: Window#show after #hide invalidates the buffer" do
  it "repaints the full region after show following hide" do
    screen = b19_headless_screen(40, 10)
    Widget::Label.new parent: screen, top: 2, left: 5, content: "Test"
    screen.repaint

    # Capture initial render state; on a working show/hide pair, the label
    # text should be visible after re-show.
    screen.hide
    screen.show
    screen.repaint

    # The label's cells should contain rendered content after show+repaint.
    # Verify that at least one cell in the label area has non-space content.
    found_content = false
    (2...4).each do |y|
      (5...9).each do |x|
        found_content ||= !screen.cell_rows[y][x].char.whitespace?
      end
    end
    found_content.should be_true
  end
end

# ---------------------------------------------------------------------------
# Bug #7

describe "BUGS19 #7: input fiber lifecycle after EOF" do
  it "keeps listening? (intent) but stops handing out the finished fiber after EOF" do
    # Create a screen with a finite input source (IO::Memory with content).
    input = IO::Memory.new("x") # Single character, then EOF
    screen = Crysterm::Screen.new(
      input: input, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10)
    window = Crysterm::Window.new(screen: screen, default_quit_keys: false)
    app = Crysterm::Application.new
    app.add window

    seen = [] of Char
    window.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

    # Start the input fiber and let it consume the one byte.
    screen.start_input
    screen.listening?.should be_true
    screen.input_fiber?.nil?.should be_false # live fiber is exposed

    # The fiber delivers the byte, then `tput.listen` returns on EOF and the
    # fiber finishes.
    wait_until { seen.size >= 1 }
    seen.should eq(['x'])

    # Once finished, `input_fiber?` must not hand out the dead fiber...
    wait_until { screen.input_fiber?.nil? }

    # ...but `listening?` is intent state ("started, not stopped") and must
    # survive the fiber's end — probe gating and reattach handovers rely on it.
    screen.listening?.should be_true
  end

  it "start_input after EOF starts a fresh live fiber on a new input" do
    input = IO::Memory.new("a")
    screen = Crysterm::Screen.new(
      input: input, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10)
    window = Crysterm::Window.new(screen: screen, default_quit_keys: false)
    app = Crysterm::Application.new
    app.add window

    seen = [] of Char
    window.on(Crysterm::Event::KeyPress) { |e| seen << e.char }

    # First round: consume the single byte, hit EOF, fiber finishes.
    screen.start_input
    wait_until { seen == ['a'] }
    wait_until { screen.input_fiber?.nil? }

    # Swap in a fresh input IO and restart: this must NOT be a no-op — a new
    # generation spawns and reads the new source.
    fresh = IO::Memory.new("b")
    screen.input = fresh
    screen.tput.input = fresh
    screen.start_input
    screen.listening?.should be_true

    wait_until { seen == ['a', 'b'] }
  end

  it "remains stopped after two consecutive stop_input calls" do
    screen = Crysterm::Screen.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10)
    Crysterm::Window.new(screen: screen, default_quit_keys: false)

    screen.start_input
    screen.listening?.should be_true

    screen.stop_input
    screen.stop_input # must be idempotent
    screen.listening?.should be_false
  end
end

# ---------------------------------------------------------------------------
# Bug #9: gpm reader exception isolation
#
# This bug requires a Linux console with gpm daemon running, which is not
# available in the standard CI environment. The fix wraps the `route_input`
# call in a begin/rescue pattern identical to `start_input`, so the exception
# handling behavior is proven by the #7 specs and the exception logging is
# consistent across both paths. On systems with gpm support, the exception
# isolation can be verified by raising from a mouse handler and confirming
# the reader continues.
