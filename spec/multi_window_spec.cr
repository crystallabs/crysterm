require "./spec_helper"

include Crysterm

# Multiple `Window` surfaces sharing one `Screen` device (one tty) — the Qt
# `QScreen` hosting several `QWindow`s. Crysterm does not composite surfaces
# (no tiling/overlay); the model is *stacked* windows, one active at a time,
# switchable with `Application#activate`, with a shared device whose lifecycle
# is reference-counted so tearing down one surface never breaks its siblings.
#
# Everything is headless (fixed-size `IO::Memory` device); `default_quit_keys:
# false` so a routed key is never intercepted as an app-quit (which calls exit).

private def shared_device
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
end

private def win_on(dev : Crysterm::Screen)
  Crysterm::Window.new(screen: dev, default_quit_keys: false)
end

describe "multiple Windows sharing one Screen" do
  it "shares the device and de-duplicates it at the app level" do
    app = Crysterm::Application.new
    dev = shared_device
    w1 = win_on dev
    w2 = win_on dev
    app.add w1
    app.add w2

    w1.screen.should be(w2.screen)
    app.windows.size.should eq 2
    app.screens.should eq [dev] # one physical device, de-duplicated
  end

  it "routes input to the active window, and #activate switches it" do
    app = Crysterm::Application.new
    dev = shared_device
    w1 = win_on dev
    w2 = win_on dev
    app.add w1
    app.add w2

    seen = [] of Int32
    w1.on(Crysterm::Event::KeyPress) { seen << 1 }
    w2.on(Crysterm::Event::KeyPress) { seen << 2 }

    # w2 is the most-recently-added → active.
    app.route_input dev, Tput::InputEvent.new('x', nil)

    app.activate(w1).should be(w1)
    app.active_window.should be(w1)
    app.route_input dev, Tput::InputEvent.new('y', nil)

    seen.should eq [2, 1] # first key to w2, second to w1 after activate
  end

  it "keeps the shared device alive when a non-last window is destroyed" do
    app = Crysterm::Application.new
    dev = shared_device
    w1 = win_on dev
    w2 = win_on dev
    app.add w1
    app.add w2
    dev.tput.is_alt.should be_true

    w2.destroy

    # The device is NOT torn down — still in the alternate buffer — and the
    # surviving window is untouched.
    dev.tput.is_alt.should be_true
    w1.connected?.should be_true
    app.windows.should eq [w1]

    # Input still reaches the survivor (now the active window on the device).
    got = 0
    w1.on(Crysterm::Event::KeyPress) { got += 1 }
    app.route_input dev, Tput::InputEvent.new('z', nil)
    got.should eq 1
  end

  it "restores the device only when the last window on it is destroyed" do
    dev = shared_device
    w1 = win_on dev
    w2 = win_on dev
    dev.tput.is_alt.should be_true

    w1.destroy
    dev.tput.is_alt.should be_true # w2 still uses the device

    w2.destroy
    dev.tput.is_alt.should be_false # last one out restored the terminal
  end
end
