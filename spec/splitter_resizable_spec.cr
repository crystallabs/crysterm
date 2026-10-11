require "./spec_helper"

# `Splitter#resizable`: locking the dividers where they are. Qt has no flag
# for it — a `QSplitterHandle` is disabled with `setEnabled(false)` — and
# that is what the lock does to the dividers: no drag, no keys, no focus,
# the layout untouched; the programmatic moves keep working.

private def three_panes(width = 31)
  s = headless_screen(80, 24)
  sp = Crysterm::Widget::Splitter.new parent: s, width: width, height: 10
  a = Crysterm::Widget::Box.new
  b = Crysterm::Widget::Box.new
  c = Crysterm::Widget::Box.new
  sp << a << b << c
  s.repaint
  {s, sp, a, b, c}
end

private def mouse(s, action, x, y, button = ::Tput::Mouse::Button::Left)
  s.dispatch_mouse ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

# Presses the divider at column *from* and drags it to column *to*.
private def drag(s, from, to)
  mouse s, ::Tput::Mouse::Action::Down, from, 2
  mouse s, ::Tput::Mouse::Action::Move, to, 2, ::Tput::Mouse::Button::None
  mouse s, ::Tput::Mouse::Action::Up, to, 2
end

private def key(div, key)
  div.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', key)
end

describe "Splitter resizable" do
  it "moves its dividers by the mouse, the keys and focus while resizable, which it is by default" do
    s, sp = three_panes
    sp.resizable?.should be_true
    sp.dividers.map(&.enabled?).should eq [true, true]
    sp.sizes.should eq [9, 9, 11]

    drag s, 9, 12
    sp.sizes.should eq [12, 6, 11]

    div = sp.dividers[0]
    div.focus
    div.focused?.should be_true
    key div, Tput::Key::Left
    sp.sizes.should eq [11, 7, 11]
  end

  it "locked, refuses the mouse, the keys and focus, and keeps the layout as it is" do
    s, sp = three_panes
    sp.dividers[0].position = 12
    sp.sizes.should eq [12, 6, 11]

    sp.resizable = false
    sp.resizable?.should be_false
    sp.dividers.map(&.enabled?).should eq [false, false]
    sp.sizes.should eq [12, 6, 11]
    sp.dividers.map(&.visible?).should eq [true, true]

    drag s, 12, 15
    sp.sizes.should eq [12, 6, 11]

    div = sp.dividers[0]
    div.focus
    div.focused?.should be_false
    key div, Tput::Key::Right
    sp.sizes.should eq [12, 6, 11]

    # The programmatic moves still work: the lock is against the hand.
    sp.sizes = [5, 13, 11]
    sp.sizes.should eq [5, 13, 11]
    sp.restore_state([10, 8, 11]).should be_true
    sp.sizes.should eq [10, 8, 11]
    sp.dividers[1].position = 20
    sp.sizes.should eq [10, 9, 10]

    # Unlocked, the dividers move again.
    sp.resizable = true
    sp.dividers.map(&.enabled?).should eq [true, true]
    key div, Tput::Key::Right
    sp.sizes.should eq [11, 8, 10]
    div.focus
    div.focused?.should be_true
  end

  it "locks a divider added while locked" do
    _, sp = three_panes
    sp.resizable = false
    sp << Crysterm::Widget::Box.new
    sp.dividers.size.should eq 3
    sp.dividers.map(&.enabled?).should eq [false, false, false]
    sp.resizable = true
    sp.dividers.map(&.enabled?).should eq [true, true, true]
  end
end
