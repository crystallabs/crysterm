require "./spec_helper"

include Crysterm

# BUGS13 M-Z menu/tool bar lifecycle regression coverage:
#   M9  — MenuBar/ToolBar#destroy must withdraw action accelerators while the
#         action collections are still populated (the Detach emitted inside
#         `super` runs the uninstall over already-cleared collections).
#   M10 — an Action added to a bar's menu AFTER add_menu (on an attached bar)
#         must get its accelerator installed.
#   M14 — a MenuBar moved to another window must re-home its pop-up menus
#         (window children) onto the new window.

private def bar_screen(width = 40, height = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

private def press(key : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', key
end

describe "BUGS13 M9: destroy withdraws accelerators" do
  it "MenuBar#destroy uninstalls its menu actions' shortcuts" do
    s = bar_screen
    bar = Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    a = Action.new "Cut", shortcut: Tput::Key::CtrlX
    fired = 0
    a.on(Crysterm::Event::Triggered) { fired += 1 }
    bar.add_menu "Edit", [a]

    s.emit press(Tput::Key::CtrlX)
    fired.should eq 1

    bar.destroy
    # The shortcut used to stay registered forever (destroy cleared @menus
    # before super emitted Detach, so the uninstall loop iterated nothing).
    s.emit press(Tput::Key::CtrlX)
    fired.should eq 1
  ensure
    s.try &.destroy
  end

  it "ToolBar#destroy uninstalls its actions' shortcuts" do
    s = bar_screen
    tb = Widget::ToolBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    a = Action.new "Bold", shortcut: Tput::Key::CtrlB
    fired = 0
    a.on(Crysterm::Event::Triggered) { fired += 1 }
    tb.add_action a

    s.emit press(Tput::Key::CtrlB)
    fired.should eq 1

    tb.destroy
    s.emit press(Tput::Key::CtrlB)
    fired.should eq 1
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M10: action added after add_menu gets its accelerator" do
  it "installs the shortcut of an action added to an attached bar's menu" do
    s = bar_screen
    bar = Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
    file = bar.add_menu "File"

    a = Action.new "New", shortcut: Tput::Key::CtrlN
    fired = 0
    a.on(Crysterm::Event::Triggered) { fired += 1 }
    file << a # the documented flow: add to the menu after add_menu

    s.emit press(Tput::Key::CtrlN)
    fired.should eq 1
  ensure
    s.try &.destroy
  end
end

describe "BUGS13 M14: menus re-home on a cross-window move" do
  it "moves the pop-up menus to the bar's new window on re-attach" do
    s1 = bar_screen
    s2 = bar_screen
    bar = Widget::MenuBar.new parent: s1, top: 0, left: 0, width: 40, height: 1
    menu = bar.add_menu "File"
    menu.add_action("New") { }
    menu.window?.should eq s1

    s1.remove bar
    s2.append bar

    bar.menus[0].window?.should eq s2
    s1.children.includes?(menu).should be_false
    s2.children.includes?(menu).should be_true
  ensure
    s1.try &.destroy
    s2.try &.destroy
  end

  it "keeps accelerators working on the new window after the move" do
    s1 = bar_screen
    s2 = bar_screen
    bar = Widget::MenuBar.new parent: s1, top: 0, left: 0, width: 40, height: 1
    a = Action.new "Cut", shortcut: Tput::Key::CtrlX
    fired = 0
    a.on(Crysterm::Event::Triggered) { fired += 1 }
    bar.add_menu "Edit", [a]

    s1.remove bar
    s2.append bar

    s2.emit press(Tput::Key::CtrlX)
    fired.should eq 1
    # And withdrawn from the old window by the Detach handler.
    s1.emit press(Tput::Key::CtrlX)
    fired.should eq 1
  ensure
    s1.try &.destroy
    s2.try &.destroy
  end
end
