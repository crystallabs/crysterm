require "./spec_helper"

include Crysterm

# Submenus by mouse alone, as a terminal delivers it: the pointer arrives on
# a row (a hover, which opens the row's submenu) and the button goes down and
# up there. Edit → Paste Special → From Kill Ring: the click on a row whose
# submenu the hover opened keeps it open rather than toggling it closed —
# which made a third-level row look dead to a click — and a click on the
# third level's entry fires it and closes the chain.

private def click_at(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, y, source: :test)
  s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
  s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::Left, x, y, source: :test)
  s.repaint
end

private def open_menus(s)
  s.descendants.select(Widget::Menu).select(&.visible?)
end

private def menu_with(s, text)
  open_menus(s).find! { |m| m.actions.any? { |a| a.text == text } }
end

private def row_of(menu, text)
  i = menu.actions.index! { |a| a.text == text }
  {menu.aleft + menu.ileft + 1, menu.atop + menu.itop + i}
end

describe "Menu nested submenus by mouse" do
  it "keeps a hover-opened submenu open on the click, down to a third level, whose entry fires" do
    s = headless_screen(80, 24)
    main = Widget::MainWindow.new parent: s
    edit = main.menu_bar.add_menu "&Edit"
    edit.add_action "&Copy"
    fired = [] of String
    one = Action.new "&1 first"
    one.on(Event::Triggered) { fired << "1" }
    two = Action.new "&2 second"
    two.on(Event::Triggered) { fired << "2" }
    ring = Action.new "From &Kill Ring"
    ring.menu = [one, two]
    terminal = Action.new "From &Terminal"
    terminal.on(Event::Triggered) { fired << "terminal" }
    edit.add_submenu "Paste &Special", [terminal, ring]
    s.repaint

    click_at s, 2, 0 # the Edit title
    open_menus(s).size.should eq 1
    x, y = row_of(edit, "Paste &Special")
    click_at s, x, y
    open_menus(s).size.should eq 2
    click_at s, x, y # again: still open
    open_menus(s).size.should eq 2
    special = menu_with(s, "From &Kill Ring")
    x, y = row_of(special, "From &Kill Ring")
    click_at s, x, y
    open_menus(s).size.should eq 3
    third = menu_with(s, "&2 second")
    x, y = row_of(third, "&2 second")
    click_at s, x, y
    fired.should eq ["2"]
    open_menus(s).should be_empty
  end
end
