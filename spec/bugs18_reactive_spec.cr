require "./spec_helper"

include Crysterm

# Regression specs for the BUGS18 reactive fixes:
#
# B18-93: `Binding#run` must execute its block untracked. The bind-time initial
#         run (`Reactive.bind` → `binding.run`) can happen while an enclosing
#         `Effect` is the active tracking scope; without suspension the
#         binding's signal reads subscribed the OUTER effect, which then re-ran
#         its whole body (re-binding!) on every change — compounding bindings
#         and duplicating side effects.
#
# B18-97: `Reactive.bind` / `Reactive.effect` / `Reactive.bind_items` installed
#         a raw, never-removed auto-dispose `Event::Destroy` hook on the owner.
#         Manual dispose (a rebind-per-reconnect cycle) left a dead handler —
#         pinning the disposed Binding/Effect and everything its block captured
#         — on the long-lived owner, once per cycle. The hooks are now routed
#         through cancellable subscriptions torn down by dispose/off.

private def rx_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

describe "BUGS18 B18-93 — Binding runs untracked" do
  it "does not graft a binding's watched signals onto an enclosing effect" do
    scr = rx_screen
    label = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3

    sig = Crysterm::Reactive::Signal.new 0
    effect_runs = 0
    binding_runs = 0
    Crysterm::Reactive.effect(label) do
      effect_runs += 1
      Crysterm::Reactive.bind(label, sig) do
        binding_runs += 1
        sig.value
      end
    end
    effect_runs.should eq 1
    binding_runs.should eq 1 # the bind-time initial run

    # Under the bug the initial run read `sig` inside the outer effect's scope,
    # so this write re-ran the whole effect body, creating a second binding.
    sig.value = 1
    effect_runs.should eq 1  # the outer effect never legitimately read `sig`
    binding_runs.should eq 2 # exactly one live binding fired

    sig.value = 2
    effect_runs.should eq 1
    binding_runs.should eq 3
  end
end

describe "BUGS18 B18-97 — auto-dispose Destroy hooks are removable" do
  it "Binding#dispose unhooks the owner's Destroy auto-dispose handler" do
    scr = rx_screen
    w = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    s = Crysterm::Reactive::Signal.new 0

    before = w.handlers(Crysterm::Event::Destroy).size
    b = Crysterm::Reactive.bind(w, s) { s.value }
    w.handlers(Crysterm::Event::Destroy).size.should eq before + 1
    b.dispose
    w.handlers(Crysterm::Event::Destroy).size.should eq before
  end

  it "repeated Binding rebind cycles accumulate no Destroy handlers" do
    scr = rx_screen
    w = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    s = Crysterm::Reactive::Signal.new 0

    before = w.handlers(Crysterm::Event::Destroy).size
    5.times do
      b = Crysterm::Reactive.bind(w, s) { s.value }
      b.dispose
    end
    w.handlers(Crysterm::Event::Destroy).size.should eq before
  end

  it "Binding still auto-disposes when the owner is destroyed" do
    scr = rx_screen
    w = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    s = Crysterm::Reactive::Signal.new 0

    runs = 0
    b = Crysterm::Reactive.bind(w, s) { runs += 1 }
    runs.should eq 1
    w.destroy
    b.disposed?.should be_true
    s.value = 1 # must not fire the disposed binding
    runs.should eq 1
  end

  it "Effect#dispose unhooks the owner's Destroy auto-dispose handler" do
    scr = rx_screen
    w = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    s = Crysterm::Reactive::Signal.new 0

    before = w.handlers(Crysterm::Event::Destroy).size
    eff = Crysterm::Reactive.effect(w) { s.value }
    w.handlers(Crysterm::Event::Destroy).size.should eq before + 1
    eff.dispose
    w.handlers(Crysterm::Event::Destroy).size.should eq before
  end

  it "Effect still auto-disposes when the owner is destroyed" do
    scr = rx_screen
    w = Crysterm::Widget::Box.new parent: scr, width: 20, height: 3
    s = Crysterm::Reactive::Signal.new 0

    runs = 0
    eff = Crysterm::Reactive.effect(w) do
      runs += 1
      s.value
    end
    runs.should eq 1
    w.destroy
    eff.disposed?.should be_true
    s.value = 1 # must not re-run the disposed effect
    runs.should eq 1
  end

  it "cancelling bind_items early unhooks the Destroy hook and stops patching" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[a b]

    before = view.handlers(Crysterm::Event::Destroy).size
    subs = Crysterm::Reactive.bind_items(view, names, &.itself)
    view.handlers(Crysterm::Event::Destroy).size.should eq before + 1
    subs.off
    view.handlers(Crysterm::Event::Destroy).size.should eq before
    names << "c" # no longer bound
    view.item_texts.should eq %w[a b]
  end

  it "bind_items still tears down when the view is destroyed" do
    scr = rx_screen
    view = Crysterm::Widget::List.new parent: scr, width: 20, height: 6
    names = Crysterm::Reactive::ObservableList(String).new %w[a b]

    Crysterm::Reactive.bind_items(view, names, &.itself)
    view.destroy
    names << "c" # must not raise or touch the destroyed view
    view.item_texts.should eq %w[a b]
  end
end
