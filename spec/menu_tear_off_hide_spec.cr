require "./spec_helper"

include Crysterm

# Tear-off (detachable) menus, continued (`src/widget/menu/tear_off.cr`): the
# original chain goes the moment the copy is torn off, mid-drag, the drag
# carrying on in the copy (`Window#hand_over_drag`); torn-off menus hide while
# the feature is off for them and come back where they were; and the status
# tip a torn-off menu put in the bar leaves with its highlight.

private alias TearOffHandle = Widget::Menu::TearOffHandle

# A main window with an editor in the central area and a bar with a View
# menu: two entries with status tips and a submenu.
private def build(s)
  main = Widget::MainWindow.new parent: s
  edit = Widget::TextEdit.new
  main.central_widget = edit
  view = main.menu_bar.add_menu "&View"
  sync = Action.new "S&ync Cursor", checkable: true
  sync.status_tip = "Keep the cursor in step"
  view << sync
  reload = view.add_action("&Reload") { }
  reload.status_tip = "Read the file again"
  view.add_submenu "Ru&lers", [Action.new("&Horizontal"), Action.new("&Vertical")]
  main.status_bar
  s.repaint
  edit.focus
  {main, view, edit}
end

private def handle_of(menu)
  menu.children.select(TearOffHandle).first?
end

private def open_menus(s)
  s.descendants.select(Widget::Menu).select(&.visible?)
end

private def row_of(menu, text)
  i = menu.actions.index! { |a| a.text == text }
  {menu.aleft + menu.ileft + 1, menu.atop + menu.itop + i}
end

private def click_at(s, x, y)
  mouse_move s, x, y
  mouse_down s, x, y
  mouse_up s, x, y
  s.repaint
end

private def press(s, key : Tput::Key)
  s.emit Event::KeyPress, kp(key: key)
end

# Tears the bar's View menu off by a drag of its strip by (*dx*, *dy*).
private def torn_view(s, main, view, dx = 20, dy = 8)
  main.menu_bar.open_menu 0
  s.repaint
  h = handle_of(view).not_nil!
  x, y = h.aleft, h.atop
  mouse_move s, x, y
  mouse_down s, x, y
  mouse_move s, x + dx, y + dy, ::Tput::Mouse::Button::Left
  mouse_up s, x + dx, y + dy
  s.repaint
  Widget::Menu.torn_off_menus(s).first
end

# A click focuses the torn-off menu *t* and the pointer highlights a row with
# a tip; it stays on the menu, so what the block does to the focus is what
# takes the highlight away (and the tip with it).
private def focus_leaves(s, main, t, &)
  rx, ry = row_of(t, "&Reload")
  sx, sy = row_of(t, "S&ync Cursor")
  click_at s, rx, ry
  s.focused.should eq t
  mouse_move s, sx, sy
  main.status_bar.message.should eq "Keep the cursor in step"
  yield
  main.status_bar.message.should eq ""
  t.visible?.should be_true
end

private def with_tear_off(on : Bool, &)
  Crysterm::Config.set "menu.tear_off", on
  begin
    yield
  ensure
    Crysterm::Config.reset "menu.tear_off"
  end
end

describe "Menu tear-off, mid-drag" do
  it "closes the original chain on the motion that tears the copy off, the copy following to the release" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, edit = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      x0, y0 = view.aleft, view.atop
      h = handle_of(view).not_nil!
      x, y = h.aleft, h.atop
      mouse_move s, x, y
      mouse_down s, x, y
      mouse_move s, x + 3, y + 2, ::Tput::Mouse::Button::Left
      # The button is still down: the original is gone already.
      t = Widget::Menu.torn_off_menus(s).first
      view.visible?.should be_false
      main.menu_bar.open_index.should be_nil
      s.popup_grab_active?.should be_false
      s.focused.should eq edit
      s.dragging?.should be_true
      s.drag_session.not_nil!.source.should eq handle_of(t)
      t.aleft.should eq x0 + 3
      t.atop.should eq y0 + 2

      mouse_move s, x + 10, y + 5, ::Tput::Mouse::Button::Left
      t.aleft.should eq x0 + 10
      t.atop.should eq y0 + 5
      mouse_up s, x + 10, y + 5
      s.repaint
      s.dragging?.should be_false
      Widget::Menu.torn_off_menus(s).should eq [t]
      t.visible?.should be_true
      t.aleft.should eq x0 + 10
      t.atop.should eq y0 + 5
    end
  end

  it "tears a submenu off mid-drag though the submenu goes with its chain" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _ = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      x, y = row_of(view, "Ru&lers")
      mouse_move s, x, y
      s.repaint
      sub = open_menus(s).find! { |m| m.parent_menu == view }
      sx0, sy0 = sub.aleft, sub.atop
      h = handle_of(sub).not_nil!
      x, y = h.aleft, h.atop
      mouse_move s, x, y
      mouse_down s, x, y
      mouse_move s, x - 2, y + 4, ::Tput::Mouse::Button::Left
      sub.window?.should be_nil # destroyed with the chain
      view.visible?.should be_false
      t = Widget::Menu.torn_off_menus(s).first
      mouse_move s, x - 4, y + 6, ::Tput::Mouse::Button::Left
      mouse_up s, x - 4, y + 6
      s.repaint
      t.aleft.should eq sx0 - 4
      t.atop.should eq sy0 + 6
      t.actions.map(&.text).should eq ["&Horizontal", "&Vertical"]
      open_menus(s).should eq [t]
    end
  end

  it "keeps the two-click drag: the lifting press and a motion tear off, the next press drops" do
    with_tear_off true do
      s = headless_screen(80, 24)
      s.drag_two_click = true
      main, view, _ = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      x0, y0 = view.aleft, view.atop
      h = handle_of(view).not_nil!
      x, y = h.aleft, h.atop
      mouse_move s, x, y
      mouse_down s, x, y
      mouse_up s, x, y
      mouse_move s, x + 6, y + 3
      view.visible?.should be_false
      t = Widget::Menu.torn_off_menus(s).first
      mouse_move s, x + 8, y + 4
      mouse_down s, x + 8, y + 4
      mouse_up s, x + 8, y + 4
      s.repaint
      s.dragging?.should be_false
      t.aleft.should eq x0 + 8
      t.atop.should eq y0 + 4
      Widget::Menu.torn_off_menus(s).should eq [t]

      # Two presses in place on the strip, no motion: a click, which tears off
      # in place.
      main.menu_bar.open_menu 0
      s.repaint
      h = handle_of(view).not_nil!
      x, y = h.aleft, h.atop
      mouse_move s, x, y
      mouse_down s, x, y
      mouse_up s, x, y
      mouse_down s, x, y
      mouse_up s, x, y
      s.repaint
      Widget::Menu.torn_off_menus(s).size.should eq 2
      view.visible?.should be_false
    end
  end
end
