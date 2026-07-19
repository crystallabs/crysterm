require "./spec_helper"

include Crysterm

# Regression specs for BUGS14 findings C1, C2, R1, R3.
#
# C1 — an animated capture built its sampling clock as
#      `FrameClock.new((1.0 / fps).seconds)`; `fps == 0` makes that
#      `Infinity.seconds`, which raises `OverflowError` at startup. Clamp
#      `fps` to at least 1 before building the clock/ffmpeg args.
# C2 — removing/destroying a NESTED widget skipped the window's transient
#      mouse-state teardown, so `@_hover`/`@_mouse_captor`/`@grabs` kept
#      pointing at the detached widget (stale MouseLeave, mouse-dead-in-capture,
#      modal-forever). `Widget#remove` must tear it down like `Window#remove`.
# R1 — `ObservableList#delete_at`/`#[]=` double-normalized an out-of-range
#      negative index, silently mutating a valid-but-wrong slot instead of
#      raising `IndexError` like a plain `Array`.
# R3 — `DragEvent#ignore` didn't withdraw the SESSION's acceptance (only the
#      event flag), so a target that accepted then `ignore`d still received a
#      Drop (the drop gate reads `session.data.accepted?`).

private def b14_window(w = 40, h = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def b14_mouse(action, x, y, button = ::Tput::Mouse::Button::None)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

# --- C1 ---------------------------------------------------------------------

describe "BUGS14 C1: capture frame-rate is clamped to >= 1" do
  it "feed_animation_frames with fps: 0 does not raise (no Infinity clock)" do
    s = b14_window
    Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
    s._render
    io = IO::Memory.new
    # Before the fix `FrameClock.new((1.0 / 0).seconds)` raised OverflowError
    # at construction. A tiny duration keeps the clock loop short.
    s.feed_animation_frames(io, 0, s.awidth, 0, s.aheight, 2.milliseconds, 0)
  end

  it "feed_animation_frames with a negative fps does not raise either" do
    s = b14_window
    Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
    s._render
    io = IO::Memory.new
    s.feed_animation_frames(io, 0, s.awidth, 0, s.aheight, 2.milliseconds, -5)
  end
end

# --- C2 ---------------------------------------------------------------------

describe "BUGS14 C2: nested-widget removal tears down window mouse-state" do
  it "clears @_hover when the hovered NESTED widget is removed" do
    s = b14_window
    outer = Widget::Box.new parent: s, left: 2, top: 2, width: 20, height: 6
    inner = Widget::Box.new parent: outer, left: 1, top: 1, width: 6, height: 3
    inner.clickable = true
    s._render

    # Drive a move onto the inner widget so it becomes the window's hover.
    lp = inner.lpos.not_nil!
    s.dispatch_mouse b14_mouse(::Tput::Mouse::Action::Move, lp.xi, lp.yi)
    s.hovered.should eq inner

    # Remove the nested widget (Widget#remove path, not Window#remove).
    outer.remove inner
    s.hovered.should be_nil
  end

  it "clears @_hover when the hovered nested widget is destroyed" do
    s = b14_window
    outer = Widget::Box.new parent: s, left: 2, top: 2, width: 20, height: 6
    inner = Widget::Box.new parent: outer, left: 1, top: 1, width: 6, height: 3
    inner.clickable = true
    s._render

    lp = inner.lpos.not_nil!
    s.dispatch_mouse b14_mouse(::Tput::Mouse::Action::Move, lp.xi, lp.yi)
    s.hovered.should eq inner

    inner.destroy
    s.hovered.should be_nil
  end

  it "clears @_mouse_captor when the capturing nested widget is removed" do
    s = b14_window
    outer = Widget::Box.new parent: s, left: 2, top: 2, width: 20, height: 6
    inner = Widget::Box.new parent: outer, left: 1, top: 1, width: 6, height: 3
    inner.clickable = true
    s._render

    s.capture_mouse inner
    s.mouse_captor.should eq inner

    outer.remove inner
    s.mouse_captor.should be_nil
  end

  it "releases a modal grab held by a removed nested widget" do
    s = b14_window
    outer = Widget::Box.new parent: s, left: 2, top: 2, width: 20, height: 6
    inner = Widget::Box.new parent: outer, left: 1, top: 1, width: 6, height: 3
    s._render

    s.add_popup_grab inner
    s.popup_grab_active?.should be_true

    outer.remove inner
    s.popup_grab_active?.should be_false
  end

  it "leaves the window mouse-state untouched for an UNRELATED removal" do
    s = b14_window
    outer = Widget::Box.new parent: s, left: 2, top: 2, width: 20, height: 6
    a = Widget::Box.new parent: outer, left: 1, top: 1, width: 6, height: 2
    b = Widget::Box.new parent: outer, left: 1, top: 3, width: 6, height: 2
    a.clickable = true
    s._render

    lp = a.lpos.not_nil!
    s.dispatch_mouse b14_mouse(::Tput::Mouse::Action::Move, lp.xi, lp.yi)
    s.hovered.should eq a

    # Removing a sibling that does NOT cover the hovered widget must not clear it.
    outer.remove b
    s.hovered.should eq a
  end
end

# --- R1 ---------------------------------------------------------------------

describe "BUGS14 R1: ObservableList#delete_at/#[]= reject out-of-range indices" do
  it "delete_at(-8) on a size-5 list raises IndexError (matching Array)" do
    l = Crysterm::Reactive::ObservableList(Int32).new [1, 2, 3, 4, 5]
    seen = [] of Int32
    l.on(Crysterm::Event::ListChanged) { |e| seen << e.index }
    expect_raises(IndexError) { l.delete_at(-8) }
    seen.should be_empty
    l.to_a.should eq [1, 2, 3, 4, 5]
  end

  it "[]=(-8) on a size-5 list raises IndexError (matching Array)" do
    l = Crysterm::Reactive::ObservableList(Int32).new [1, 2, 3, 4, 5]
    seen = [] of Int32
    l.on(Crysterm::Event::ListChanged) { |e| seen << e.index }
    expect_raises(IndexError) { l[-8] = 99 }
    seen.should be_empty
    l.to_a.should eq [1, 2, 3, 4, 5]
  end

  it "still accepts valid negative indices" do
    l = Crysterm::Reactive::ObservableList(Int32).new [1, 2, 3, 4, 5]
    l.delete_at(-1).should eq 5
    l.to_a.should eq [1, 2, 3, 4]
    l[-1] = 40
    l.to_a.should eq [1, 2, 3, 40]
  end
end

# --- R3 ---------------------------------------------------------------------

describe "BUGS14 R3: DragEvent#ignore withdraws the session's acceptance" do
  it "accept then ignore leaves session.data.accepted? false" do
    s = b14_window
    src = Widget::Box.new parent: s, left: 0, top: 0, width: 4, height: 2
    data = Crysterm::DragData.new(src)
    session = Crysterm::DragSession.new(src, data, 0, 0, Crysterm::DragSensor::Mouse)
    e = Crysterm::Event::DragOver.new(session)

    e.accept
    e.accepted?.should be_true
    e.session.data.accepted?.should be_true

    e.ignore
    e.accepted?.should be_false
    # The regression: this used to stay true, so a "rejected" drop still fired.
    e.session.data.accepted?.should be_false
  end
end
