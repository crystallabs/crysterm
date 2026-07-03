require "./spec_helper"

include Crysterm

# Regression specs for the BUGS-F2 subscription/fiber/process-leak cluster
# (findings 3, 10, 11, 12, 33, 44, 45). The house rule under test: "every `on`
# at construction has an `off` at destroy"; every self-driven clock stops when
# the widget goes away.
#
# Findings verified at runtime (10, 11, 33, 44) build a real headless window and
# assert handler/subscription counts drop to zero and clocks stop after destroy.
# Findings whose trigger needs a live decoder / child process (3, 45) or a full
# CSS recascade under a running FrameClock (12) are pinned with source-structure
# assertions, the same technique `bugs5_lifecycle_spec.cr` uses for its
# ffmpeg-only invariant.

private def leak_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def read_src(rel : String) : String
  File.read(File.join(__DIR__, "..", "src", rel))
end

# --------------------------------------------------------------------------
# Finding 10: Menu / ToolBar leak per-action Changed handlers + associations
# --------------------------------------------------------------------------

describe "Menu per-action handler/association cleanup (F2 #10)" do
  it "removes every action's Changed handler and dissociates on destroy" do
    s = leak_window
    menu = Crysterm::Widget::Menu.new parent: s

    a = menu.add "One"
    b = menu.add "Two"

    # `<<`/`add` wired a Changed handler on each action and associated the menu.
    a.handlers(Crysterm::Event::Changed).size.should eq 1
    b.handlers(Crysterm::Event::Changed).size.should eq 1
    a.associated_widgets.includes?(menu).should be_true
    b.associated_widgets.includes?(menu).should be_true

    menu.destroy

    # No stale handler left to run sync_items/selekt/request_render on the dead
    # menu, and no dead menu pinned in the action's associated set.
    a.handlers(Crysterm::Event::Changed).size.should eq 0
    b.handlers(Crysterm::Event::Changed).size.should eq 0
    a.associated_widgets.includes?(menu).should be_false
    b.associated_widgets.includes?(menu).should be_false
    menu.actions.empty?.should be_true
  ensure
    s.try &.destroy
  end
end

describe "ToolBar per-action handler/association cleanup (F2 #10)" do
  it "removes each backing action's Changed handler and dissociates on destroy" do
    s = leak_window
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: 40, height: 1

    bold = Crysterm::Action.new "Bold"
    bold.checkable = true
    tb.add_action bold

    bold.handlers(Crysterm::Event::Changed).size.should eq 1
    bold.associated_widgets.includes?(tb).should be_true

    tb.destroy

    bold.handlers(Crysterm::Event::Changed).size.should eq 0
    bold.associated_widgets.includes?(tb).should be_false
  ensure
    s.try &.destroy
  end
end

# --------------------------------------------------------------------------
# Finding 11: effect widgets stop their FrameClock on destroy
# --------------------------------------------------------------------------

describe "Effect widgets stop their animation on destroy (F2 #11)" do
  it "CopperBar (Animated) stops on destroy" do
    s = leak_window
    bar = Crysterm::Widget::Effect::CopperBar.new parent: s, width: 10, height: 1
    bar.start
    bar.running?.should be_true
    bar.destroy
    bar.running?.should be_false
  ensure
    s.try &.destroy
  end

  it "Matrix (Direct) stops on destroy" do
    s = leak_window
    m = Crysterm::Widget::Effect::Matrix.new parent: s, width: 10, height: 5
    m.start
    m.running?.should be_true
    m.destroy
    m.running?.should be_false
  ensure
    s.try &.destroy
  end

  it "Spray (Direct) stops on destroy" do
    s = leak_window
    sp = Crysterm::Widget::Effect::Spray.new parent: s, width: 10, height: 5
    sp.start
    sp.running?.should be_true
    sp.destroy
    sp.running?.should be_false
  ensure
    s.try &.destroy
  end

  it "SineScroller (Animated) stops on destroy" do
    s = leak_window
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, width: 20, height: 6, text: "HI"
    sc.start
    sc.running?.should be_true
    sc.destroy
    sc.running?.should be_false
  ensure
    s.try &.destroy
  end

  it "Marquee (Animated) stops on destroy" do
    s = leak_window
    mq = Crysterm::Widget::Marquee.new parent: s, width: 20, height: 1, text: "NEWS  "
    mq.start
    mq.running?.should be_true
    mq.destroy
    mq.running?.should be_false
  ensure
    s.try &.destroy
  end

  it "the Destroy hook is installed once, not per start/stop cycle" do
    s = leak_window
    bar = Crysterm::Widget::Effect::CopperBar.new parent: s, width: 10, height: 1
    bar.start
    bar.stop
    bar.start
    bar.stop
    bar.start
    # Repeated start/stop must not accumulate Destroy handlers.
    bar.handlers(Crysterm::Event::Destroy).size.should eq 1
    bar.destroy
    bar.running?.should be_false
  ensure
    s.try &.destroy
  end
end

# --------------------------------------------------------------------------
# Finding 33: Gradient unsubscribes from a shared animate: clock on destroy
# --------------------------------------------------------------------------

describe "Gradient shared-clock subscription cleanup (F2 #33)" do
  it "removes its Tick handler from a shared clock on destroy" do
    s = leak_window
    clock = Crysterm::Timer.new(0.1.seconds, autostart: false)
    clock.handlers(Crysterm::Event::Tick).size.should eq 0

    g = Crysterm::Widget::Gradient.new parent: s, width: 20, height: 2, animate: clock
    clock.handlers(Crysterm::Event::Tick).size.should eq 1

    g.destroy
    # The caller's long-lived clock no longer pokes the destroyed widget.
    clock.handlers(Crysterm::Event::Tick).size.should eq 0
  ensure
    s.try &.destroy
  end

  it "creating/destroying many gradients against one clock doesn't accumulate handlers" do
    s = leak_window
    clock = Crysterm::Timer.new(0.1.seconds, autostart: false)
    5.times do
      g = Crysterm::Widget::Gradient.new parent: s, width: 20, height: 2, animate: clock
      g.destroy
    end
    clock.handlers(Crysterm::Event::Tick).size.should eq 0
  ensure
    s.try &.destroy
  end
end

# --------------------------------------------------------------------------
# Finding 44: Message keypress-dismiss subscription removed on destroy
# --------------------------------------------------------------------------

describe "Message keypress-dismiss subscription cleanup (F2 #44)" do
  it "removes the window keypress handler on destroy" do
    s = leak_window
    msg = Crysterm::Widget::Message.new parent: s, width: 20, height: 3

    before = s.handlers(Crysterm::Event::KeyPress).size
    # `display(text, nil)` arms a keypress-dismiss handler on the window.
    msg.display("hi", nil) { }
    s.handlers(Crysterm::Event::KeyPress).size.should eq before + 1

    msg.destroy
    # Destroying the message before any key is pressed must drop that handler,
    # or the next keypress runs end_it against the dead widget.
    s.handlers(Crysterm::Event::KeyPress).size.should eq before
  ensure
    s.try &.destroy
  end
end

# --------------------------------------------------------------------------
# Finding 3: shared-clock streaming video honours advance_stream's false return
# --------------------------------------------------------------------------

describe "Media shared-clock stream termination (F2 #3)" do
  # A live EOF+failed-restart needs a running ffmpeg; assert instead the
  # structural invariant the fix relies on: `tick_frame` must NOT discard
  # `advance_stream`'s result — on false it stops playback and unsubscribes from
  # the clock, mirroring `stream_loop` (which does `break unless advance_stream`).
  it "tick_frame stops playback and unsubscribes when advance_stream returns false" do
    src = read_src "widget_media_base.cr"
    body_start = src.index!("private def tick_frame")
    body_end = src.index!("private def unsubscribe_clock", body_start)
    body = src[body_start...body_end]

    body.should contain("unless advance_stream")
    body.should contain("@playing = false")
    body.should contain("unsubscribe_clock")
    # The old bug was a bare `advance_stream st` whose result was thrown away.
    body.should_not match(/^\s*advance_stream st\s*$/m)
  end

  it "advance_stream latches a permanently failed restart so ffmpeg isn't respawned" do
    src = read_src "widget_media_base.cr"
    body_start = src.index!("private def advance_stream")
    body_end = src.index!("protected def invalidate_frame", body_start)
    body = src[body_start...body_end]

    # A failed `stream.restart` sets @load_failed so `#source` won't reopen it.
    body.should contain("@load_failed = true")
  end
end

# --------------------------------------------------------------------------
# Finding 12: CSS @keyframes animation resolves its Style per-tick (not captured)
# --------------------------------------------------------------------------

describe "CSS keyframes animation Style resolution (F2 #12)" do
  # A recascade replaces the widget's Style wholesale; a clock that captured the
  # old object would be orphaned. Assert `start_css_animation` resolves `style`
  # inside the tick block instead of capturing `st = style` once.
  it "start_css_animation does not capture the Style up front" do
    src = read_src "widget_animation.cr"
    body_start = src.index!("private def start_css_animation")
    body_end = src.index!("private def resolve_keyframes", body_start)
    body = src[body_start...body_end]

    # The fix removes the `st = style` capture and passes the freshly-resolved
    # `style` to apply_keyframe on each tick.
    body.should_not contain("st = style")
    body.should contain("apply_keyframe stops, style")
  end
end

# --------------------------------------------------------------------------
# Finding 45: Terminal child-exit performs a real teardown, not a bare emit
# --------------------------------------------------------------------------

describe "Terminal child-exit teardown (F2 #45)" do
  # A live PTY child exit needs a subprocess and the render fiber to drain the
  # UI queue; assert the structural invariant: the reader fiber marshals a real
  # `destroy` onto the render fiber after emitting Exit, and no longer emits a
  # bare `Event::Destroy` (which left the widget attached and could fire twice).
  it "posts a real destroy on child exit and drops the bare Destroy emit" do
    src = read_src "widget/terminal.cr"

    src.should contain("emit ::Crysterm::Event::Exit, code")
    src.should contain("window?.try &.post { destroy }")
    # The bare emit must be gone from the exit path.
    src.should_not contain("emit ::Crysterm::Event::Destroy")
  end

  it "keeps kill idempotent" do
    # `kill` nils @pty so a second call (Destroy handler after post{destroy}) is a
    # no-op; Pty#kill is itself guarded by @closed.
    src = read_src "widget/terminal.cr"
    kill_start = src.index!("def kill")
    kill_body = src[kill_start, 120]
    kill_body.should contain("@pty = nil")
  end
end
