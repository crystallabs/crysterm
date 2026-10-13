require "./spec_helper"

include Crysterm

# An action shown or hidden in an open menu (`Menu#refresh_rows`) leaves
# the highlight on the action it was on, as Qt's `QMenu` keeps its active
# action, rather than on the row index it was at — which would move it to
# another action and close a submenu open off the highlighted row.

private def press(w, key : Tput::Key)
  w.handle_key_press Crysterm::Event::KeyPress.new('\0', key)
end

private def hover(s, x, y)
  s.dispatch_mouse Tput::Mouse::Event.new(Tput::Mouse::Action::Move, Tput::Mouse::Button::None, x, y, source: :test)
end

private def row_of(menu, text)
  i = menu.actions.select(&.visible?).index! { |a| a.text == text }
  {menu.aleft + menu.ileft + 1, menu.atop + menu.itop + i}
end

describe "Widget::Menu: a row shown or hidden while open" do
  it "keeps the highlight on its action" do
    s = headless_screen(80, 24)
    main = Widget::MainWindow.new parent: s
    file = main.menu_bar.add_menu "File"
    alpha = file.add_action("Alpha") { }
    file.add_action("Beta") { }
    gamma = file.add_action("Gamma") { }
    file.add_action("Delta") { }
    main.menu_bar.open_menu 0
    s.repaint
    file.select_first_action
    press file, Tput::Key::Down
    press file, Tput::Key::Down
    file.selected_action.should eq gamma
    alpha.visible = false
    file.selected_action.should eq gamma
    alpha.visible = true
    file.selected_action.should eq gamma
  end

  it "keeps a submenu open off the highlighted row" do
    s = headless_screen(80, 24)
    main = Widget::MainWindow.new parent: s
    file = main.menu_bar.add_menu "File"
    alpha = file.add_action("Alpha") { }
    file.add_action("Beta") { }
    recent = file.add_submenu "Recent", [Action.new("one"), Action.new("two")]
    file.add_action("Delta") { }
    main.menu_bar.open_menu 0
    s.repaint
    x, y = row_of(file, "Recent")
    hover s, x, y
    s.repaint
    open = -> { s.descendants.select(Widget::Menu).count(&.visible?) }
    open.call.should eq 2
    alpha.visible = false
    s.repaint
    file.selected_action.should eq recent
    open.call.should eq 2
  end
end
