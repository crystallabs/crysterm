require "./spec_helper"

include Crysterm

# Unit spec for `Subscription` / `Subscriptions` (FORMAL-WIDGETS B6.1): the
# tracked-subscription primitive that owns the `on` → store-`Wrapper` → `off`
# triple the dropdown/dialog/media widgets otherwise hand-rolled. The spec
# deliberately spans several *event classes* (Focus/Blur/Resize/Show) and two
# *target types* (a `Widget` and a `Window`), because the concern the doc flags
# is codegen across that heterogeneity, not any one behavior.

private def sub_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

describe Crysterm::Subscription do
  it "fires while active and stops after #off" do
    s = sub_screen
    w = Widget::Box.new parent: s

    fired = 0
    sub = Crysterm::Subscription.new
    sub.active?.should be_false
    sub.on(w, Crysterm::Event::Focus) { fired += 1 }
    sub.active?.should be_true

    w.emit Crysterm::Event::Focus
    fired.should eq 1

    sub.off
    sub.active?.should be_false
    w.emit Crysterm::Event::Focus
    fired.should eq 1 # no longer listening
  end

  it "has an idempotent #off" do
    s = sub_screen
    w = Widget::Box.new parent: s
    sub = Crysterm::Subscription.new
    sub.on(w, Crysterm::Event::Blur) { }
    sub.off
    sub.off # no crash, no double-remove
    sub.active?.should be_false
  end

  it "cancels the previous handler when re-armed on the same slot" do
    s = sub_screen
    w = Widget::Box.new parent: s

    old = 0
    new = 0
    sub = Crysterm::Subscription.new
    sub.on(w, Crysterm::Event::Show) { old += 1 }
    sub.on(w, Crysterm::Event::Show) { new += 1 } # replaces, doesn't stack

    w.emit Crysterm::Event::Show
    old.should eq 0 # the first handler was cancelled by the re-arm
    new.should eq 1
  end

  it "removes from the exact target it subscribed on (captured, not re-fetched)" do
    # The window/window? hazard: subscribe on the window directly; teardown must
    # reach that same emitter via the captured reference, not a re-fetch.
    s = sub_screen

    fired = 0
    sub = Crysterm::Subscription.new
    sub.on(s, Crysterm::Event::Resize) { fired += 1 }
    s.emit Crysterm::Event::Resize
    fired.should eq 1

    sub.off # captured `s`, so this reaches the window regardless of `w.window?`
    s.emit Crysterm::Event::Resize
    fired.should eq 1
  end
end

describe Crysterm::Subscriptions do
  it "tracks heterogeneous subscriptions and tears them all down together" do
    s = sub_screen
    w = Widget::Box.new parent: s

    focus = 0
    blur = 0
    resize = 0
    subs = Crysterm::Subscriptions.new
    subs.empty?.should be_true

    subs.on(w, Crysterm::Event::Focus) { focus += 1 }
    subs.on(w, Crysterm::Event::Blur) { blur += 1 }
    subs.on(s, Crysterm::Event::Resize) { resize += 1 } # different target + event class
    subs.empty?.should be_false

    w.emit Crysterm::Event::Focus
    w.emit Crysterm::Event::Blur
    s.emit Crysterm::Event::Resize
    {focus, blur, resize}.should eq({1, 1, 1})

    subs.off
    subs.empty?.should be_true
    w.emit Crysterm::Event::Focus
    w.emit Crysterm::Event::Blur
    s.emit Crysterm::Event::Resize
    {focus, blur, resize}.should eq({1, 1, 1}) # nothing fired after bulk off

    subs.off # idempotent
  end

  it "returns each Subscription so one can be cancelled individually" do
    s = sub_screen
    w = Widget::Box.new parent: s

    a = 0
    b = 0
    subs = Crysterm::Subscriptions.new
    one = subs.on(w, Crysterm::Event::Focus) { a += 1 }
    subs.on(w, Crysterm::Event::Blur) { b += 1 }

    one.off # cancel just the first
    w.emit Crysterm::Event::Focus
    w.emit Crysterm::Event::Blur
    a.should eq 0
    b.should eq 1

    subs.off # the bulk off still cleanly handles the already-cancelled one
    w.emit Crysterm::Event::Blur
    b.should eq 1
  end
end
