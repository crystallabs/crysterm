require "./spec_helper"

include Crysterm

# Qt's `QMenu`/`QMenuBar` keyboard rules for two cases:
#
#   - A mnemonic letter several entries share moves the highlight to the
#     next of them, cycling, and activates nothing; a unique one activates.
#     Alt+letter shared by several bar titles opens the next of them.
#   - Tab and Shift+Tab in a popped-up menu (a bar's, a context menu, a
#     submenu) are Down and Up, where they moved the focus out from under
#     the open menu — a context menu then stayed up with the keyboard gone.

private def build(s)
  main = Widget::MainWindow.new parent: s
  edit = Widget::TextEdit.new
  main.central_widget = edit
  fm = main.menu_bar.add_menu "&File"
  fired = [] of String
  fm.add_action("&New") { fired << "New" }
  fm.add_action("&Save") { fired << "Save" }
  fm.add_action("&Select") { fired << "Select" }
  fm.add_separator
  fm.add_action("S&ort") { fired << "Sort" }
  main.menu_bar.add_menu "&Edit", [Action.new("&Cut")]
  main.menu_bar.add_menu "Fo&rmat", [Action.new("&Bold")]
  main.menu_bar.add_menu "&Fold", [Action.new("&All")]
  s.repaint
  edit.focus
  {main, fm, edit, fired}
end

private def press(s, key : Tput::Key? = nil, char = '\0')
  s.emit Event::KeyPress, kp(char, key)
  s.repaint
end

describe "Menu mnemonic clashes and Tab" do
  it "cycles a shared item mnemonic without activating, and activates a unique one" do
    s = headless_screen(80, 24)
    main, fm, _edit, fired = build(s)
    press s, Tput::Key::AltF
    press s, nil, 's'
    main.menu_bar.open_index.should eq 0
    fm.selected_action.not_nil!.text.should eq "&Save"
    press s, nil, 's'
    fm.selected_action.not_nil!.text.should eq "&Select"
    press s, nil, 'S'
    fm.selected_action.not_nil!.text.should eq "&Save" # wraps
    fired.should be_empty

    press s, nil, 'o'
    fired.should eq ["Sort"]
    main.menu_bar.open_index.should be_nil
  end

  it "opens the next bar title sharing an Alt mnemonic" do
    s = headless_screen(80, 24)
    main, _fm, _edit, _fired = build(s)
    press s, Tput::Key::AltF
    main.menu_bar.open_index.should eq 0
    press s, Tput::Key::AltF
    main.menu_bar.open_index.should eq 3
    press s, Tput::Key::AltF
    main.menu_bar.open_index.should eq 0
  end

  it "takes Tab and Shift+Tab as Down and Up in a bar's menu" do
    s = headless_screen(80, 24)
    main, fm, _edit, _fired = build(s)
    press s, Tput::Key::AltF
    fm.current_index.should eq 0
    press s, Tput::Key::Tab
    main.menu_bar.open_index.should eq 0
    s.focused.should be fm
    fm.current_index.should eq 1
    press s, Tput::Key::ShiftTab
    press s, Tput::Key::ShiftTab
    fm.current_index.should eq 4 # wrapped past the separator
  end

  it "keeps the keyboard in a context menu on Tab, so Escape still closes it" do
    s = headless_screen(80, 24)
    _main, _fm, edit, _fired = build(s)
    m = Widget::Menu.new parent: s
    m.add_action("A") { }
    m.add_action("B") { }
    m.popup 5, 5
    s.repaint
    press s, Tput::Key::Tab
    s.focused.should be m
    m.visible?.should be_true
    press s, Tput::Key::Escape
    m.visible?.should be_false
    s.focused.should be edit
  end
end
