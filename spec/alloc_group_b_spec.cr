require "./spec_helper"

include Crysterm

# Regression specs for ALLOCS.md Group B (mouse/event/shortcut dispatch
# allocation reductions). These assert that the *behavior* of the hot paths is
# unchanged after removing per-call allocations:
#
#   * B1 — `Window#widget_at` allocation-free traversal (topmost/skip/z-order).
#   * B2 — pooled, reused `Event::Mouse` family objects (still reach listeners
#          with the right coords/button; the object is reused across reports).
#   * B4 — Widget-context shortcut activation still gates on host focus.

private def gb_screen(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h)
end

private def gb_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

describe "ALLOCS Group B1 — widget_at traversal" do
  it "returns the topmost (last-in-tree) overlapping widget" do
    s = gb_screen
    a = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    a.clickable = true
    b = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    b.clickable = true

    s.widget_at(8, 7).should eq b
  end

  it "honors z-index over tree order" do
    s = gb_screen
    top = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    top.clickable = true
    top.style.z_index = 10
    base = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    base.clickable = true

    s.widget_at(8, 7).should eq top
  end

  it "skips the given widget and falls through to the one below" do
    s = gb_screen
    a = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    a.clickable = true
    b = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    b.clickable = true

    # Skip removes exactly one widget: without skip the topmost is `b`;
    # skipping `b` yields the one beneath (`a`); skipping `a` still leaves `b`.
    s.widget_at(8, 7, skip: b).should eq a
    s.widget_at(8, 7, skip: a).should eq b
  end

  it "returns nil when the sole candidate is skipped" do
    s = gb_screen
    a = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    a.clickable = true
    s.widget_at(8, 7, skip: a).should be_nil
  end

  it "recurses into a skipped widget's subtree (skip is per-widget, not per-subtree)" do
    s = gb_screen
    outer = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    outer.clickable = true
    inner = Widget::Box.new parent: outer, left: 0, top: 0, width: 10, height: 6
    inner.clickable = true

    # Skipping `outer` must NOT skip its child `inner`, which still occupies
    # the point and is later in pre-order, so it is the hit.
    s.widget_at(8, 7, skip: outer).should eq inner
  end

  it "returns nil when no widget covers the point" do
    s = gb_screen
    a = Widget::Box.new parent: s, left: 5, top: 5, width: 4, height: 4
    a.clickable = true
    s.widget_at(30, 15).should be_nil
  end
end

describe "ALLOCS Group B2 — pooled mouse events" do
  it "delivers the correct coords/button to a screen-level listener" do
    s = gb_screen
    got_x = got_y = -1
    got_button = ::Tput::Mouse::Button::None
    s.on(Crysterm::Event::Mouse) do |e|
      got_x = e.x
      got_y = e.y
      got_button = e.button
    end

    s.dispatch_mouse gb_mouse(::Tput::Mouse::Action::Down, 7, 9)
    got_x.should eq 7
    got_y.should eq 9
    got_button.should eq ::Tput::Mouse::Button::Left
  end

  it "reuses one pooled Event::Mouse object across reports (no per-report alloc)" do
    s = gb_screen
    seen = [] of Crysterm::Event::Mouse
    s.on(Crysterm::Event::Mouse) { |e| seen << e }

    s.dispatch_mouse gb_mouse(::Tput::Mouse::Action::Move, 3, 3)
    s.dispatch_mouse gb_mouse(::Tput::Mouse::Action::Move, 4, 4)

    seen.size.should eq 2
    # Same pooled instance re-targeted, not two fresh allocations.
    seen[0].should be seen[1]
    # ...and it carries the *latest* report's coords after reuse.
    seen[1].x.should eq 4
    seen[1].y.should eq 4
  end

  it "resets `accepted` between reports on the reused object" do
    s = gb_screen
    w = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 10
    w.clickable = true
    accept_next = true
    w.on(Crysterm::Event::Mouse) do |e|
      e.accept if accept_next
    end

    # First report accepted.
    s.dispatch_mouse gb_mouse(::Tput::Mouse::Action::Down, 2, 2)
    # Second report: handler does not accept; the pooled object must have had
    # `accepted` cleared by `reset`, so it reads false again.
    accept_next = false
    last = nil.as(Crysterm::Event::Mouse?)
    w.on(Crysterm::Event::Mouse) { |e| last = e }
    s.dispatch_mouse gb_mouse(::Tput::Mouse::Action::Down, 2, 2)
    last.not_nil!.accepted?.should be_false
  end

  it "delivers hover MouseEnter/MouseLeave via pooled events" do
    s = gb_screen
    a = Widget::Box.new parent: s, left: 0, top: 0, width: 5, height: 5
    a.clickable = true
    b = Widget::Box.new parent: s, left: 10, top: 0, width: 5, height: 5
    b.clickable = true

    overs = [] of Int32
    outs = [] of Int32
    a.on(Crysterm::Event::MouseEnter) { |e| overs << e.x }
    a.on(Crysterm::Event::MouseLeave) { |e| outs << e.x }

    s.dispatch_mouse gb_mouse(::Tput::Mouse::Action::Move, 2, 2)  # enter a
    s.dispatch_mouse gb_mouse(::Tput::Mouse::Action::Move, 12, 2) # leave a -> enter b
    overs.should eq [2]
    outs.should eq [12]
  end
end

describe "ALLOCS Group B4 — shortcut host-focus gating" do
  it "fires a Widget-context shortcut only while its host is focused" do
    s = gb_screen
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    other = Crysterm::Widget::Box.new parent: s, top: 2, left: 0, width: 5, height: 1, keys: true

    a = Action.new "Bold", shortcut: Tput::Key::CtrlB,
      shortcut_context: Action::ShortcutContext::Widget
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a

    # Host not focused: does not fire.
    other.focus
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 0

    # Host focused: fires.
    tb.focus
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1
  end

  it "does not fire on a non-matching key even while the host is focused" do
    s = gb_screen
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Bold", shortcut: Tput::Key::CtrlB,
      shortcut_context: Action::ShortcutContext::Widget
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a
    tb.focus

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlA)
    fired.should eq 0
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1
  end

  it "still completes a two-stroke chord while the host stays focused" do
    s = gb_screen
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Bold", shortcuts: [[Tput::Key::CtrlK, Tput::Key::CtrlB]],
      shortcut_context: Action::ShortcutContext::Widget
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a
    tb.focus

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK)
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1
  end
end
