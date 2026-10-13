require "./spec_helper"

# Several `Window`s stacked on one terminal (`Screen`), as Qt stacks
# top-level windows on one screen: hiding the one shown hands the terminal to
# the one below instead of leaving the alternate screen, a hidden window is
# never the one shown (nor made so by `Application#activate`), `#show` brings
# it up on top, a hidden window reattached elsewhere stays hidden, and a wipe
# of the terminal by one window counts as a wipe for all of them.

private def shared_device
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 10)
end

private def win_on(dev : Crysterm::Screen)
  Crysterm::Window.new(screen: dev, default_quit_keys: false)
end

describe "Windows sharing a terminal" do
  it "marks every window on the terminal wiped when one clears it" do
    app = Crysterm::Application.new
    dev = shared_device
    w1 = win_on dev
    w2 = win_on dev
    app.add w1
    app.add w2
    w2.repaint
    w1.repaint
    w1.wiped?.should be_false
    w2.wiped?.should be_false

    # Raising w1 clears what w2 left on the terminal, its pictures included.
    app.activate w1
    w2.wiped?.should be_true
  ensure
    w1.try &.destroy
    w2.try &.destroy
  end

  it "hands the terminal to a visible sibling on hide, keeping the alternate screen" do
    app = Crysterm::Application.new
    dev = shared_device
    w1 = win_on dev
    w2 = win_on dev
    app.add w1
    app.add w2

    w2.hide
    dev.tput.is_alt.should be_true
    app.active_window_for(dev).should be(w1)
    app.active_window.should be(w1)

    w1.hide
    dev.tput.is_alt.should be_false # the last visible one gives the terminal back
  ensure
    w1.try &.destroy
    w2.try &.destroy
  end

  it "keeps a visible sibling shown when a hidden window is activated, and shows it on top" do
    app = Crysterm::Application.new
    dev = shared_device
    w1 = win_on dev
    w2 = win_on dev
    app.add w1
    app.add w2

    w1.hide
    app.activate w1
    w1.visible?.should be_false
    app.active_window_for(dev).should be(w2)

    w1.show
    app.active_window_for(dev).should be(w1)
    app.active_window.should be(w1)
  ensure
    w1.try &.destroy
    w2.try &.destroy
  end

  it "keeps a hidden window hidden when it is reattached, until #show" do
    w = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    w.hide
    out2 = IO::Memory.new
    w.connect IO::Memory.new, out2
    w.tput.flush
    w.visible?.should be_false
    w.tput.is_alt.should be_false
    out2.to_s.should_not contain "\e[?1049h"

    w.show
    w.tput.flush
    w.tput.is_alt.should be_true
  ensure
    w.try &.destroy
  end
end
