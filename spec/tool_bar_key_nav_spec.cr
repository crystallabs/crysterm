require "./spec_helper"

include Crysterm

# Keyboard operation of a focused ToolBar: F6 landing on the bar lights the
# current button (the cue that Left/Right now walk the strip), and Space/Enter
# carry the same nuance as menu rows — Space toggles a checkable button in
# place with focus staying on the bar, while Enter (and Space on anything
# non-checkable) fires the button and returns focus to the central area, the
# toolbar analog of a menu's activate-and-dismiss.

private def toolbar_screen
  s = headless_screen(80, 24)
  tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: 60, height: 1
  opened = [false]
  tb.add_button("Open") { opened[0] = true }
  bold = Crysterm::Action.new "Bold", checkable: true
  tb.add_action bold
  central = Crysterm::Widget::Box.new parent: s, keys: true, top: 5, left: 0, width: 10, height: 1
  s.repaint
  central.focus
  {s, tb, bold, opened, central}
end

private def press(s, key : Tput::Key)
  s.emit Crysterm::Event::KeyPress, kp(key: key)
end

private def press_char(s, c : Char)
  s.emit Crysterm::Event::KeyPress, kp(c)
end

describe "ToolBar keyboard navigation" do
  it "lights the current button while focused, and clears the cue on leaving" do
    s, tb, _bold, _opened, central = toolbar_screen

    press s, Tput::Key::F6
    s.focused.same?(tb).should be_true
    tb.@item_boxes[0].state.selected?.should be_true

    press s, Tput::Key::Escape
    s.focused.same?(central).should be_true
    tb.@item_boxes[0].state.selected?.should be_false
  end

  it "moves the lit cursor with Left/Right" do
    s, tb, _bold, _opened, _central = toolbar_screen

    press s, Tput::Key::F6
    press s, Tput::Key::Right
    tb.@item_boxes[1].state.selected?.should be_true
    tb.@item_boxes[0].state.selected?.should be_false

    press s, Tput::Key::Left
    tb.@item_boxes[0].state.selected?.should be_true
    tb.@item_boxes[1].state.selected?.should be_false
  end

  it "Space toggles a checkable button in place, focus staying on the bar" do
    s, tb, bold, _opened, _central = toolbar_screen

    press s, Tput::Key::F6
    press s, Tput::Key::Right # onto Bold
    press_char s, ' '
    bold.checked?.should be_true
    s.focused.same?(tb).should be_true

    press_char s, ' ' # ... so it can be flipped right back
    bold.checked?.should be_false
    s.focused.same?(tb).should be_true
  end

  it "Space on a non-checkable button fires it and returns focus to the central area" do
    s, _tb, _bold, opened, central = toolbar_screen

    press s, Tput::Key::F6
    press_char s, ' '
    opened[0].should be_true
    s.focused.same?(central).should be_true
  end

  it "Enter keeps fire-and-leave, even on a checkable button" do
    s, _tb, bold, _opened, central = toolbar_screen

    press s, Tput::Key::F6
    press s, Tput::Key::Right # onto Bold
    press s, Tput::Key::Enter
    bold.checked?.should be_true
    s.focused.same?(central).should be_true
  end

  it "keeps a checked button lit after focus leaves, while the cursor cue goes out" do
    s, tb, bold, _opened, _central = toolbar_screen

    press s, Tput::Key::F6
    press s, Tput::Key::Right # onto Bold
    press_char s, ' '
    bold.checked?.should be_true
    press s, Tput::Key::Escape
    tb.@item_boxes[1].state.selected?.should be_true # checked state survives blur
    tb.@item_boxes[0].state.selected?.should be_false
  end

  it "is a no-op on a disabled action: nothing fires, focus stays on the bar" do
    s, tb, _bold, _opened, _central = toolbar_screen
    fired = [false]
    reload = Crysterm::Action.new "Reload"
    reload.on(Crysterm::Event::Triggered) { fired[0] = true }
    reload.enabled = false
    tb.add_action reload
    s.repaint

    press s, Tput::Key::F6
    press s, Tput::Key::Right
    press s, Tput::Key::Right # onto Reload
    press s, Tput::Key::Enter
    fired[0].should be_false
    s.focused.same?(tb).should be_true
  end
end
