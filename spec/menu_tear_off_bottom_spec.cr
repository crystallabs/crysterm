require "./spec_helper"

include Crysterm

# The tear-off strip on a menu's bottom border row (`src/widget/menu/tear_off.cr`):
# the same strip as the top one, on the other edge — placed by the same
# geometry, torn off and moved by a drag or a click the same way, the copy
# keeping the grabbed point under the pointer.

private alias TearOffHandle = Widget::Menu::TearOffHandle

private def build(s)
  main = Widget::MainWindow.new parent: s
  view = main.menu_bar.add_menu "&View"
  view << Action.new("S&ync Cursor", checkable: true)
  view.add_action("&Reload") { }
  view.add_submenu "Ru&lers", [Action.new("&Horizontal"), Action.new("&Vertical")]
  s.repaint
  {main, view}
end

private def bottom_of(menu)
  menu.tear_off_handle?(Crysterm::Side::Bottom)
end

private def click_at(s, x, y)
  mouse_move s, x, y
  mouse_down s, x, y
  mouse_up s, x, y
  s.repaint
end

private def drag_handle(s, handle, dx, dy)
  x, y = handle.aleft + 1, handle.atop
  mouse_move s, x, y
  mouse_down s, x, y
  mouse_move s, x + dx, y + dy, ::Tput::Mouse::Button::Left
  mouse_up s, x + dx, y + dy
  s.repaint
end

private def with_tear_off(on : Bool, &)
  Crysterm::Config.set "menu.tear_off", on
  begin
    yield
  ensure
    Crysterm::Config.reset "menu.tear_off"
  end
end

describe "Menu tear-off, bottom strip" do
  it "puts a strip in the middle of the bottom border row, under the top one" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      top = view.tear_off_handle?(Crysterm::Side::Top).not_nil!
      bottom = bottom_of(view).not_nil!
      bottom.edge.bottom?.should be_true
      bottom.atop.should eq view.atop + view.aheight - 1
      bottom.aleft.should eq top.aleft
      bottom.content.should eq "⠿⠿⠿"
      # The theme's bottom border row is reused, not added to.
      view.aheight.should eq view.actions.size + 2
      (s.dump(bottom.aleft, bottom.aleft + 3, bottom.atop, bottom.atop + 1) || "").should contain "⠿⠿⠿"
      view.children.count(&.is_a?(TearOffHandle)).should eq 2
    end
  end

  it "shows no bottom strip while the option is off, and gives a borderless menu its box back" do
    with_tear_off false do
      s = headless_screen(80, 24)
      m = Widget::Menu.new(parent: s, style: Style.new(border: false))
      m.add_action "&One"
      m.popup 2, 2
      s.repaint
      bottom_of(m).should be_nil
      m.tear_off_enabled = true
      s.repaint
      m.style.border_view.bottom.should eq 1
      m.aheight.should eq 3
      bottom_of(m).not_nil!.atop.should eq m.atop + 2
      m.tear_off_enabled = false
      s.repaint
      bottom_of(m).should be_nil
      m.style.border_view.top.should eq 0
      m.style.border_view.bottom.should eq 0
      m.aheight.should eq 1
    end
  end

  it "tears a copy off on a drag of the bottom strip, keeping the grabbed point under the pointer" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      x0, y0 = view.aleft, view.atop
      drag_handle s, bottom_of(view).not_nil!, 10, 3
      torn = Widget::Menu.torn_off_menus(s)
      torn.size.should eq 1
      t = torn.first
      t.aleft.should eq x0 + 10
      t.atop.should eq y0 + 3
      view.visible?.should be_false
      main.menu_bar.open_index.should be_nil
      # The copy has both strips too; the close mark stays on the top row.
      b = bottom_of(t).not_nil!
      b.atop.should eq t.atop + t.aheight - 1
      t.tear_off_handle?(Crysterm::Side::Top).not_nil!.atop.should eq t.atop
      closes = t.children.reject(TearOffHandle).select { |c| c.content == Glyphs[Glyphs::Role::CloseButton, Glyphs::Tier::Unicode].to_s }
      closes.size.should eq 1
      closes.first.atop.should eq t.atop
    end
  end

  it "tears off in place on a click of the bottom strip" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      x0, y0 = view.aleft, view.atop
      b = bottom_of(view).not_nil!
      click_at s, b.aleft, b.atop
      t = Widget::Menu.torn_off_menus(s).first
      t.aleft.should eq x0
      t.atop.should eq y0
      view.visible?.should be_false
    end
  end

  it "moves a torn-off menu by its bottom strip, tearing nothing further off" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      drag_handle s, view.tear_off_handle?(Crysterm::Side::Top).not_nil!, 10, 5
      t = Widget::Menu.torn_off_menus(s).first
      x0, y0 = t.aleft, t.atop
      drag_handle s, bottom_of(t).not_nil!, -4, 4
      t.aleft.should eq x0 - 4
      t.atop.should eq y0 + 4
      Widget::Menu.torn_off_menus(s).should eq [t]
    end
  end
end
