require "./spec_helper"

include Crysterm

# A hidden `MenuBar` — an application's full-screen view — answers neither
# its activation key nor its Alt letters, and takes an open menu down with it.

private def press(s, key : Tput::Key)
  e = Crysterm::Event::KeyPress.new '\0', key
  s.emit Crysterm::Event::KeyPress, e
  e
end

describe "MenuBar hidden" do
  it "closes an open menu when hidden, and ignores F10 and the Alt letters while hidden" do
    s = headless_screen(80, 24)
    main = Widget::MainWindow.new parent: s
    bar = main.menu_bar
    bar.add_menu "&File", [Action.new("New")]
    bar.add_menu "&Edit", [Action.new("Cut")]
    central = Widget::Box.new parent: s, keys: true, top: 5, left: 0, width: 10, height: 1
    main.central_widget = central
    s.repaint
    central.focus

    press(s, Tput::Key::AltE).accepted?.should be_true
    bar.menus[1].visible?.should be_true
    bar.hide
    bar.menus[1].visible?.should be_false
    s.focused.should eq central
    press(s, Tput::Key::F10).accepted?.should be_false
    press(s, Tput::Key::AltF).accepted?.should be_false
    bar.menus.any?(&.visible?).should be_false
    s.focused.should eq central

    bar.show
    s.repaint
    press(s, Tput::Key::AltF).accepted?.should be_true
    bar.menus[0].visible?.should be_true
    bar.close
  end

  it "does not answer inside a hidden container either" do
    s = headless_screen(80, 24)
    holder = Widget::Box.new parent: s, top: 0, left: 0, width: 80, height: 10
    bar = Widget::MenuBar.new parent: holder, top: 0, left: 0, width: 40, height: 1
    bar.add_menu "&File", [Action.new("New")]
    s.repaint
    holder.hide
    press(s, Tput::Key::AltF).accepted?.should be_false
    bar.menus[0].visible?.should be_false
  end
end
