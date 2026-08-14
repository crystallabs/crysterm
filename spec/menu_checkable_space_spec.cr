require "./spec_helper"

include Crysterm

# Space on a highlighted *checkable* menu row toggles it in place without
# dismissing the menu (GTK check-menu-item behavior; a deliberate divergence
# from Qt's always-dismiss), so several options can be flipped in one visit.
# Enter keeps activate-and-close, and Space on a non-checkable row still
# activates and closes as before.

private def press(w, key : Tput::Key)
  w.handle_key_press Crysterm::Event::KeyPress.new('\0', key)
end

private def press_char(w, c : Char)
  w.handle_key_press Crysterm::Event::KeyPress.new(c)
end

private def checkable_menu(s)
  bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
  wrap = Crysterm::Action.new "Wrap", checkable: true
  plain_fired = [false]
  plain = Crysterm::Action.new "Reload"
  plain.on(Crysterm::Event::Triggered) { plain_fired[0] = true }
  menu = bar.add_menu "View", [wrap, plain]
  s.repaint
  {bar, menu, wrap, plain_fired}
end

describe "Menu Space on checkable rows" do
  it "toggles the highlighted checkable action without closing the menu" do
    s = headless_screen(80, 24)
    bar, menu, wrap, _ = checkable_menu(s)
    bar.open 0
    menu.select_first_action # highlight "Wrap"

    press_char menu, ' '
    wrap.checked?.should be_true
    bar.open_index.should eq 0 # still open ...
    menu.visible?.should be_true

    press_char menu, ' ' # ... so it can be flipped right back
    wrap.checked?.should be_false
    bar.open_index.should eq 0
  end

  it "keeps Enter as activate-and-close, even on a checkable row" do
    s = headless_screen(80, 24)
    bar, menu, wrap, _ = checkable_menu(s)
    bar.open 0
    menu.select_first_action

    press menu, Tput::Key::Enter
    wrap.checked?.should be_true
    bar.open_index.nil?.should be_true
    menu.visible?.should be_false
  end

  it "keeps Space as activate-and-close on a non-checkable row" do
    s = headless_screen(80, 24)
    bar, menu, _wrap, plain_fired = checkable_menu(s)
    bar.open 0
    menu.select_first_action
    press menu, Tput::Key::Down # onto "Reload"

    press_char menu, ' '
    plain_fired[0].should be_true
    bar.open_index.nil?.should be_true
  end
end
