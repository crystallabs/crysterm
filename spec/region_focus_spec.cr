require "./spec_helper"

include Crysterm

# Chrome-region focus cycling (`window_region_focus.cr`): the window's F6 /
# Shift+F6 handling walks a ring of the chrome bars (menu bar, tool bars, an
# interactive status bar — `Widget#region_focusable?`) in visual order plus the
# central area, and Escape returns from any bar straight to the central-area
# widget that was focused before entering chrome. Bars stay off the Tab chain
# (`FocusPolicy::Click`); this is their keyboard route in.

private def region_screen
  s = headless_screen(80, 24)
  mb = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
  mb.add_menu "File", [Crysterm::Action.new("New")]
  tb = Crysterm::Widget::ToolBar.new parent: s, top: 1, left: 0, width: 40, height: 1
  tb.add_button("Open") { }
  sb = Crysterm::Widget::StatusBar.new parent: s, bottom: 0, left: 0, width: 40, height: 1
  central = Crysterm::Widget::Box.new parent: s, keys: true, top: 5, left: 0, width: 10, height: 1
  s.repaint
  central.focus
  {s, mb, tb, sb, central}
end

private def press(s, key : Tput::Key)
  s.emit Crysterm::Event::KeyPress, kp(key: key)
end

describe "F6/Shift+F6 chrome-region cycling" do
  it "cycles central -> menu bar -> tool bar -> central, skipping a non-interactive status bar" do
    s, mb, tb, _sb, central = region_screen

    press s, Tput::Key::F6
    s.focused.same?(mb).should be_true

    press s, Tput::Key::F6
    s.focused.same?(tb).should be_true

    # The empty StatusBar has no focus target, so the next stop is already the
    # central area — restored to the exact widget focused before entering.
    press s, Tput::Key::F6
    s.focused.same?(central).should be_true
  end

  it "cycles backward with Shift+F6 (legacy F18), entering chrome at the last region" do
    s, mb, tb, _sb, central = region_screen

    press s, Tput::Key::F18
    s.focused.same?(tb).should be_true

    press s, Tput::Key::F18
    s.focused.same?(mb).should be_true

    press s, Tput::Key::F18
    s.focused.same?(central).should be_true
  end

  it "returns focus to the central widget on Escape from any bar" do
    s, _mb, tb, _sb, central = region_screen

    press s, Tput::Key::F6
    press s, Tput::Key::F6
    s.focused.same?(tb).should be_true

    press s, Tput::Key::Escape
    s.focused.same?(central).should be_true
  end

  it "stops on a status bar once it hosts a focusable widget" do
    s, mb, tb, sb, central = region_screen
    inside = Crysterm::Widget::Box.new parent: sb, keys: true, top: 0, left: 30, width: 5, height: 1
    s.repaint

    press s, Tput::Key::F6 # menu bar
    press s, Tput::Key::F6 # tool bar
    press s, Tput::Key::F6 # status bar -> its focusable child
    s.focused.same?(inside).should be_true

    press s, Tput::Key::F6
    s.focused.same?(central).should be_true
    mb.region_focusable?.should be_true # sanity: ring order was visual, not accidental
    tb.region_focusable?.should be_true
  end

  it "honors region_focusable = false as a per-bar opt-out" do
    s, mb, tb, _sb, central = region_screen
    mb.region_focusable = false

    press s, Tput::Key::F6
    s.focused.same?(tb).should be_true
    press s, Tput::Key::F6
    s.focused.same?(central).should be_true
  end

  it "honors region_navigation = false as the window-level kill switch" do
    s, _mb, _tb, _sb, central = region_screen
    s.region_navigation = false

    press s, Tput::Key::F6
    s.focused.same?(central).should be_true
  end

  it "keeps Tab traversal clear of the bars either way" do
    s, _mb, _tb, _sb, central = region_screen
    other = Crysterm::Widget::Box.new parent: s, keys: true, top: 7, left: 0, width: 10, height: 1
    s.repaint
    central.focus

    press s, Tput::Key::Tab
    s.focused.same?(other).should be_true
    press s, Tput::Key::Tab
    s.focused.same?(central).should be_true
  end

  it "falls back to the first central Tab target when the remembered widget is gone" do
    s, mb, _tb, _sb, central = region_screen
    other = Crysterm::Widget::Box.new parent: s, keys: true, top: 7, left: 0, width: 10, height: 1
    s.repaint
    central.focus

    press s, Tput::Key::F6
    s.focused.same?(mb).should be_true

    central.hide
    press s, Tput::Key::Escape
    s.focused.same?(other).should be_true
  end
end
