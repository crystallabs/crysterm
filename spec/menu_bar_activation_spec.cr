require "./spec_helper"

include Crysterm

# `MenuBar#activation_key` — the dedicated window-level bar-activation key
# (F10 by default, the Windows/GTK convention; reassignable to e.g. F9 for the
# Midnight Commander muscle memory, or nil to disable). Toggle semantics:
# activate remembers the focused widget and focuses the bar; a second press —
# or Escape with no menu open — closes any open menu and gives that widget
# focus back.

private def activation_screen
  s = headless_screen(80, 24)
  bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
  bar.add_menu "File", [Crysterm::Action.new("New")]
  bar.add_menu "Edit", [Crysterm::Action.new("Cut")]
  central = Crysterm::Widget::Box.new parent: s, keys: true, top: 5, left: 0, width: 10, height: 1
  s.repaint
  central.focus
  {s, bar, central}
end

private def press(s, key : Tput::Key)
  s.emit Crysterm::Event::KeyPress, kp(key: key)
end

describe "MenuBar#activation_key" do
  it "toggles between the bar and the previously focused widget on F10" do
    s, bar, central = activation_screen

    press s, Tput::Key::F10
    s.focused.same?(bar).should be_true

    press s, Tput::Key::F10
    s.focused.same?(central).should be_true
  end

  it "returns focus on Escape from the activated bar" do
    s, bar, central = activation_screen

    press s, Tput::Key::F10
    s.focused.same?(bar).should be_true

    press s, Tput::Key::Escape
    s.focused.same?(central).should be_true
  end

  it "closes an open menu and returns focus when pressed while a menu is open" do
    s, bar, central = activation_screen

    press s, Tput::Key::F10
    press s, Tput::Key::Down # drop the highlighted menu
    bar.open_index.should eq 0

    press s, Tput::Key::F10
    bar.open_index.nil?.should be_true
    s.focused.same?(central).should be_true
  end

  it "can be reassigned (F9) — the default key then does nothing" do
    s, bar, central = activation_screen
    bar.activation_key = Tput::Key::F9

    press s, Tput::Key::F10
    s.focused.same?(central).should be_true

    press s, Tput::Key::F9
    s.focused.same?(bar).should be_true
  end

  it "can be disabled with nil" do
    s, _bar, central = activation_screen
    _bar.activation_key = nil

    press s, Tput::Key::F10
    s.focused.same?(central).should be_true
  end

  it "does not steal the key from a focused widget that consumed it" do
    s, _bar, central = activation_screen
    central.on(Crysterm::Event::KeyPress) do |e|
      e.accept if e.key == Tput::Key::F10
    end

    press s, Tput::Key::F10
    s.focused.same?(central).should be_true
  end
end
