require "./spec_helper"

include Crysterm

# Spec for `Menu`'s adoption of `Overlay::DismissSession` (FORMAL-WIDGETS Part A
# Piece 2 — the last of the four sites) plus the Piece 4 `#treat_as_inside`
# helper. Menu's two hand-rolled watchers (`@ev_popup`/`@ev_outside`) and the
# manual `window.add_popup_grab self` collapse to a grab-owning popup session and a
# no-grab submenu session; teardown runs via the session's captured window.
#
# The existing tool-button spec covers the toggle-reopen path end-to-end; these
# examples pin the grab *lifecycle* the session now owns — the thing
# `DismissSession` exists to get right.

private def menu_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

private def press_at(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test)
end

private def popup_menu(s)
  menu = Crysterm::Widget::Menu.new parent: s, width: 12, height: 4
  menu.add_action "Open"
  menu.add_action "Save"
  s.repaint
  menu
end

describe "Menu DismissSession adoption (FORMAL-WIDGETS Part A)" do
  it "takes a modal grab on #popup and releases it on #hide_popup" do
    s = menu_screen
    menu = popup_menu s

    s.popup_grab_active?.should be_false
    menu.popup 2, 2
    menu.visible?.should be_true
    s.popup_grab_active?.should be_true # the popup session took the modal grab

    menu.hide_popup
    menu.visible?.should be_false
    s.popup_grab_active?.should be_false # ...and released it via the session's window
  end

  it "dismisses (and releases the grab) on a press outside the menu" do
    s = menu_screen
    menu = popup_menu s

    menu.popup 2, 2
    s.repaint
    s.popup_grab_active?.should be_true

    press_at s, 70, 20 # well outside the menu box
    menu.visible?.should be_false
    s.popup_grab_active?.should be_false
  end

  it "a press on a #treat_as_inside region is not a click-away" do
    s = menu_screen
    menu = popup_menu s
    # An extra region (e.g. an owning MenuBar title / ToolButton / Calendar nav
    # bar) counts as inside the grab, so a press there does not dismiss.
    menu.treat_as_inside { |_x, y| y == 0 } # the top screen row is "inside"

    menu.popup 2, 2 # menu box sits at top >= 2, clear of row 0
    s.repaint
    s.popup_grab_active?.should be_true

    press_at s, 5, 0 # in the extra region → still open
    menu.visible?.should be_true
    s.popup_grab_active?.should be_true

    press_at s, 70, 20 # truly outside → now dismissed
    menu.visible?.should be_false
    s.popup_grab_active?.should be_false
  end
end
