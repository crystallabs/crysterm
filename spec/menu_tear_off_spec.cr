require "./spec_helper"

include Crysterm

# Tear-off (detachable) menus — `menu.tear_off`, `Menu#tear_off_enabled=`,
# `Menu#torn_off?` (`src/widget/menu/tear_off.cr`): the grab strip on a menu's
# top border row, the torn-off copy a drag (or a click) of it makes, and what
# that copy does and does not do.

private alias TearOffHandle = Widget::Menu::TearOffHandle

# A bar with a View menu: a checkable entry, a plain one and a submenu.
private def build(s)
  main = Widget::MainWindow.new parent: s
  view = main.menu_bar.add_menu "&View"
  sync = Action.new "S&ync Cursor", checkable: true
  view << sync
  fired = [] of String
  view.add_action("&Reload") { fired << "reload" }
  horizontal = Action.new "&Horizontal"
  horizontal.on(Event::Triggered) { fired << "horizontal" }
  view.add_submenu "Ru&lers", [horizontal, Action.new("&Vertical")]
  s.repaint
  {main, view, sync, fired}
end

private def handle_of(menu)
  menu.children.select(TearOffHandle).first?
end

private def close_of(menu)
  menu.children.find { |c| !c.is_a?(TearOffHandle) && c.content == Glyphs[Glyphs::Role::CloseButton, Glyphs::Tier::Unicode].to_s }
end

private def open_menus(s)
  s.descendants.select(Widget::Menu).select(&.visible?)
end

private def row_of(menu, text)
  i = menu.actions.index! { |a| a.text == text }
  {menu.aleft + menu.ileft + 1, menu.atop + menu.itop + i}
end

# The pointer arrives (a terminal reports the move first), the button goes
# down and up there.
private def click_at(s, x, y)
  mouse_move s, x, y
  mouse_down s, x, y
  mouse_up s, x, y
  s.repaint
end

# A press on the strip, motion by (*dx*, *dy*) with the button held, release.
private def drag_handle(s, handle, dx, dy)
  x, y = handle.aleft, handle.atop
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

describe "Menu tear-off" do
  it "shows no strip while the option is off" do
    with_tear_off false do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      handle_of(view).should be_nil
      view.tear_off_enabled?.should be_false
      Widget::Menu.torn_off_menus(s).should be_empty
    end
  end

  it "puts the strip in the middle of the top border row of a pop-up and of a submenu" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      handle = handle_of(view).should_not be_nil
      handle.atop.should eq view.atop # the border row
      handle.aleft.should eq view.aleft + (view.awidth - 3) // 2
      handle.content.should eq "⠿⠿⠿"
      # The row under the strip is still the first entry: the theme's border
      # row is reused, not added to.
      view.itop.should eq 1
      view.aheight.should eq view.actions.size + 2

      x, y = row_of(view, "Ru&lers")
      mouse_move s, x, y # a hover opens the submenu
      s.repaint
      sub = open_menus(s).find! { |m| m.actions.any? { |a| a.text == "&Horizontal" } }
      handle_of(sub).should_not be_nil
      handle_of(sub).not_nil!.atop.should eq sub.atop
    end
  end

  it "forces a top border on a menu whose style has none, for the strip alone" do
    with_tear_off true do
      s = headless_screen(80, 24)
      m = Widget::Menu.new(parent: s, style: Style.new(border: false))
      m.add_action "&One"
      m.add_action "&Two"
      s.repaint
      m.style.border_view.top.should eq 1
      m.style.border_view.left.should eq 0
      m.style.border_view.bottom.should eq 0
      m.itop.should eq 1
      handle_of(m).not_nil!.atop.should eq m.atop
    end
    with_tear_off false do
      s = headless_screen(80, 24)
      m = Widget::Menu.new(parent: s, style: Style.new(border: false))
      m.add_action "&One"
      s.repaint
      m.style.border_view.top.should eq 0
      m.itop.should eq 0
    end
  end

  it "gives an inline-styled menu its borderless box back when tear-off is turned off" do
    with_tear_off false do
      s = headless_screen(40, 10)
      m = Widget::Menu.new(parent: s, style: Style.new(border: false))
      m.add_action "&One"
      m.add_action "&Two"
      m.popup 2, 2
      s.repaint
      rows = -> { (2..4).map { |y| (s.dump(2, 12, y, y + 1) || "").lines[2][1..-2].strip } }
      m.itop.should eq 0
      rows.call.first(2).should eq ["One", "Two"]

      m.tear_off_enabled = true
      s.repaint
      m.itop.should eq 1
      m.style.border_view.top.should eq 1
      handle_of(m).not_nil!.atop.should eq m.atop
      rows.call[0].should contain Glyphs[Glyphs::Role::TearOffHandle, Glyphs::Tier::Unicode].to_s
      rows.call[1].should eq "One"

      m.tear_off_enabled = false
      s.repaint
      handle_of(m).should be_nil
      m.style.border_view.top.should eq 0
      m.itop.should eq 0
      rows.call.first(2).should eq ["One", "Two"]
    end
  end

  it "tears a copy off on a drag of the strip, sharing the actions, and closes the original chain" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, sync, fired = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      x0, y0 = view.aleft, view.atop
      drag_handle s, handle_of(view).not_nil!, 10, 5

      torn = Widget::Menu.torn_off_menus(s)
      torn.size.should eq 1
      t = torn.first
      t.torn_off?.should be_true
      t.torn_source.should eq view
      t.actions.should eq view.actions # the very same Action objects
      t.aleft.should eq x0 + 10
      t.atop.should eq y0 + 5
      t.awidth.should eq view.awidth
      t.aheight.should eq view.aheight
      s.children.last.should eq t # in front
      view.torn_off?.should be_false
      # The original chain went down as on a leaf activation.
      view.visible?.should be_false
      main.menu_bar.open_index.should be_nil
      s.popup_grab_active?.should be_false

      # Its strip and close mark sit on its top row; firing an entry toggles the
      # shared action and leaves the torn-off menu up.
      handle_of(t).not_nil!.atop.should eq t.atop
      close_of(t).not_nil!.atop.should eq t.atop
      close_of(t).not_nil!.aleft.should eq t.aleft + t.awidth - 2
      x, y = row_of(t, "S&ync Cursor")
      click_at s, x, y
      sync.checked?.should be_true
      t.visible?.should be_true
      s.children.includes?(t).should be_true
      s.focused.should eq t # a click on a row focuses it
      x, y = row_of(t, "&Reload")
      click_at s, x, y
      fired.should eq ["reload"]
      t.visible?.should be_true
      # The original menu still lists the entries, checked alike.
      main.menu_bar.open_menu 0
      s.repaint
      view.actions[0].checked?.should be_true
      view.visible?.should be_true
      main.menu_bar.close
    end
  end

  it "tears off in place on a click of the strip without motion" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      x0, y0 = view.aleft, view.atop
      handle = handle_of(view).not_nil!
      click_at s, handle.aleft, handle.atop
      t = Widget::Menu.torn_off_menus(s).first
      t.aleft.should eq x0
      t.atop.should eq y0
      view.visible?.should be_false
    end
  end

  it "is not dismissed by an outside click or Escape, which hands the keyboard back" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      edit = Widget::TextEdit.new parent: s, top: 2, width: "100%", height: 10
      edit.focus
      s.repaint
      main.menu_bar.open_menu 0
      s.repaint
      drag_handle s, handle_of(view).not_nil!, 20, 8
      t = Widget::Menu.torn_off_menus(s).first
      click_at s, 70, 22 # far from it
      t.visible?.should be_true
      s.children.includes?(t).should be_true

      x, y = row_of(t, "&Reload")
      click_at s, x, y
      s.focused.should eq t
      s.emit Event::KeyPress, Event::KeyPress.new('\0', Tput::Key::Escape)
      s.focused.should eq edit # back to the central area
      t.visible?.should be_true
      Widget::Menu.torn_off_menus(s).should eq [t]
    end
  end

  it "closes a submenu fired inside it but stays itself, and is closed by its close mark" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _, fired = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      drag_handle s, handle_of(view).not_nil!, 10, 5
      t = Widget::Menu.torn_off_menus(s).first
      x, y = row_of(t, "Ru&lers")
      mouse_move s, x, y
      s.repaint
      sub = open_menus(s).find! { |m| m.actions.any? { |a| a.text == "&Horizontal" } }
      sub.parent_menu.should eq t
      x, y = row_of(sub, "&Horizontal")
      click_at s, x, y
      fired.should eq ["horizontal"]
      open_menus(s).should eq [t]

      close = close_of(t).not_nil!
      click_at s, close.aleft, close.atop
      Widget::Menu.torn_off_menus(s).should be_empty
      s.children.includes?(t).should be_false
      t.window?.should be_nil
    end
  end

  it "moves a torn-off menu by its strip, tearing nothing further off" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      drag_handle s, handle_of(view).not_nil!, 10, 5
      t = Widget::Menu.torn_off_menus(s).first
      x0, y0 = t.aleft, t.atop
      drag_handle s, handle_of(t).not_nil!, -4, 6
      t.aleft.should eq x0 - 4
      t.atop.should eq y0 + 6
      Widget::Menu.torn_off_menus(s).should eq [t]
    end
  end

  it "takes a per-menu override that submenus inherit, and hides its torn-off menus while the option is off" do
    with_tear_off false do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      view.tear_off_enabled = true
      view.tear_off_enabled?.should be_true
      main.menu_bar.open_menu 0
      s.repaint
      handle_of(view).should_not be_nil
      x, y = row_of(view, "Ru&lers")
      mouse_move s, x, y
      s.repaint
      sub = open_menus(s).find! { |m| m.actions.any? { |a| a.text == "&Horizontal" } }
      sub.tear_off_enabled?.should be_true
      handle_of(sub).should_not be_nil
      main.menu_bar.close

      view.tear_off_enabled = nil
      main.menu_bar.open_menu 0
      s.repaint
      handle_of(view).should be_nil
      main.menu_bar.close
    end
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      view.tear_off_enabled = false
      main.menu_bar.open_menu 0
      s.repaint
      handle_of(view).should be_nil
      view.tear_off_enabled = nil
      s.repaint
      drag_handle s, handle_of(view).not_nil!, 5, 5
      t = Widget::Menu.torn_off_menus(s).first
      # The option goes off under it: the strip leaves the ordinary menus and
      # the torn-off menu hides, until the option comes back on.
      Crysterm::Config.set "menu.tear_off", false
      main.menu_bar.open_menu 0
      s.repaint
      handle_of(view).should be_nil
      t.visible?.should be_false
      main.menu_bar.close
      Crysterm::Config.set "menu.tear_off", true
      s.repaint
      t.visible?.should be_true
      handle_of(t).should_not be_nil
      close_of(t).should_not be_nil
    end
  end

  it "is raised by a press on it, not by one on what is drawn over it" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      drag_handle s, handle_of(view).not_nil!, 20, 8
      t = Widget::Menu.torn_off_menus(s).first
      # A dialog's stand-in covering the torn-off menu: in the menus' compositing
      # layer (the theme's `z-index: 10`, a `.popup` dialog's too), so the later
      # child is the one drawn on top, and keyable, so the hit test stops at it
      # as it would at a dialog's controls.
      over = Widget::Box.new parent: s, left: t.aleft - 2, top: t.atop - 1,
        width: t.awidth + 4, height: t.aheight + 2, content: "dialog", keys: true,
        style: Style.new(z_index: 10)
      over.to_front
      s.repaint
      click_at s, t.aleft + 1, t.atop + 1 # on the dialog, over the menu's row
      s.children.last.should eq over
      # Out from under it, a press on a row lifts the menu again.
      over.hide
      s.repaint
      click_at s, t.aleft + 1, t.atop + 1
      s.children.last.should eq t
    end
  end

  it "sends its status tips to the bar it was torn off, as the original chain did" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, sync, _ = build(s)
      main.status_bar
      sync.status_tip = "Keep the cursor in step"
      main.menu_bar.open_menu 0
      s.repaint
      drag_handle s, handle_of(view).not_nil!, 20, 8
      t = Widget::Menu.torn_off_menus(s).first
      x, y = row_of(t, "S&ync Cursor")
      mouse_move s, x, y
      main.status_bar.message.should eq "Keep the cursor in step"
      x, y = row_of(t, "&Reload") # no tip: cleared
      mouse_move s, x, y
      main.status_bar.message.should eq ""
    end
  end

  it "relays its hovered actions to the bar it was torn off, through a copy torn off its own submenu too" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, sync, _ = build(s)
      main.status_bar
      horizontal = view.actions.last.menu.not_nil!.first
      horizontal.status_tip = "Rulers across the top"
      on_bar = [] of Action?
      main.menu_bar.on(Event::ActionHovered) { |e| on_bar << e.action }
      main.menu_bar.open_menu 0
      s.repaint
      drag_handle s, handle_of(view).not_nil!, 20, 4
      t = Widget::Menu.torn_off_menus(s).first
      x, y = row_of(t, "S&ync Cursor")
      mouse_move s, x, y
      on_bar.last.should eq sync

      # The copy's submenu, torn off in turn: its chain ends at the copy, whose
      # own chain ends at the bar's menu.
      x, y = row_of(t, "Ru&lers")
      mouse_move s, x, y
      s.repaint
      sub = open_menus(s).find! { |m| m.parent_menu == t }
      drag_handle s, handle_of(sub).not_nil!, 0, 6
      t2 = (Widget::Menu.torn_off_menus(s) - [t]).first
      t2.torn_source.should be_nil # the submenu went with the close of the copy's chain
      t.visible?.should be_true    # the copy stays, its submenu closed
      open_menus(s).should eq [t, t2]
      x, y = row_of(t2, "&Horizontal")
      mouse_move s, x, y
      main.status_bar.message.should eq "Rulers across the top"
      on_bar.last.should eq horizontal
    end
  end

  it "follows actions added to the original while it lives" do
    with_tear_off true do
      s = headless_screen(80, 24)
      main, view, _, _ = build(s)
      main.menu_bar.open_menu 0
      s.repaint
      drag_handle s, handle_of(view).not_nil!, 10, 5
      t = Widget::Menu.torn_off_menus(s).first
      view.add_action "&Zoom"
      t.actions.map(&.text).should eq view.actions.map(&.text)
      t.actions.last.should eq view.actions.last
      s.repaint
      t.aheight.should eq view.actions.size + 2
    end
  end
end
