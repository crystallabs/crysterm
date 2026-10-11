require "./spec_helper"

include Crysterm

# `Menu#add_action` takes the entry's shortcut along with its text (Qt's
# `QMenu::addAction(text, shortcut, functor)`), so a menu is built in one
# line per entry, with the key shown in its right-hand column and live on
# the bar's window.

private def key(k : Tput::Key) : Event::KeyPress
  Event::KeyPress.new '\0', k
end

describe "Widget::Menu#add_action with a shortcut" do
  it "takes the shortcut in Qt's text, as a key or as a sequence" do
    s = headless_screen(40, 8)
    bar = Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    file = bar.add_menu "&File"
    opened = 0
    open = file.add_action("&Open…", shortcut: "Ctrl+O") { opened += 1 }
    save = file.add_action "&Save", shortcut: Tput::Key::CtrlS
    bold = file.add_action "&Bold", shortcut: [Tput::Key::CtrlK, Tput::Key::CtrlB]
    plain = file.add_action "&Plain"
    open.shortcut_text.should eq "Ctrl+O"
    save.shortcut_text.should eq "Ctrl+S"
    bold.shortcut_text.should eq "Ctrl+K, Ctrl+B"
    plain.shortcut_text.should eq ""

    # Live on the window without the menu open, as the bar installs them.
    s.emit Event::KeyPress, key(Tput::Key::CtrlO)
    opened.should eq 1

    bar.open_menu 0
    s.repaint
    row = s.dump.to_s.lines.find(&.includes?("Open…")) || fail("the menu does not show Open…")
    row.should contain "Ctrl+O"
    s.destroy
  end
end
