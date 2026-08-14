require "./spec_helper"

include Crysterm

# Keyboard navigation contract for a focused `MenuBar` and its menus:
#
#   - Up/Down cycle the open menu's entries, wrapping to the opposite end
#     (skipping separators); Up as the very first key lands on the last entry.
#   - Right on an entry with children opens its submenu with the first child
#     selected; on a leaf (at any submenu depth) it moves to the next
#     top-level menu, wrapping past the last title.
#   - Left closes one submenu level per press until the top-level menu; from
#     the top level it moves to the previous title, wrapping past the first.
#   - Down/Up/Space on the bar itself open the highlighted menu with its
#     first (Down/Space) or last (Up) entry selected.

private def press(w, key : Tput::Key)
  w.handle_key_press Crysterm::Event::KeyPress.new('\0', key)
end

private def nav_bar(s)
  bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: 40, height: 1
  fm = bar.add_menu "File"
  fm.add_action("New") { }
  fm.add_separator
  fm.add_submenu "Recent", [Crysterm::Action.new("old-1"), Crysterm::Action.new("old-2")]
  bar.add_menu "Edit", [Crysterm::Action.new("Cut")]
  bar.add_menu "Help", [Crysterm::Action.new("About")]
  s.repaint
  {bar, fm}
end

describe "MenuBar keyboard navigation" do
  it "wraps Up/Down at the menu's ends, skipping separators" do
    s = headless_screen(80, 24)
    _bar, fm = nav_bar(s)
    fm.select_first_action
    fm.current_index.should eq 0 # "New"

    press fm, Tput::Key::Up      # wrap backward off the top ...
    fm.current_index.should eq 2 # ... onto "Recent", past the separator

    press fm, Tput::Key::Down # wrap forward off the bottom
    fm.current_index.should eq 0
  end

  it "reveals the highlight on the last entry when Up is the first key" do
    s = headless_screen(80, 24)
    _bar, fm = nav_bar(s)
    fm.focus
    press fm, Tput::Key::Up
    fm.@show_highlight.should be_true
    fm.current_index.should eq 2 # "Recent" — last selectable entry
  end

  it "opens the highlighted menu from the bar with an entry preselected" do
    s = headless_screen(80, 24)
    bar, fm = nav_bar(s)
    bar.focus

    press bar, Tput::Key::Down
    bar.open_index.should eq 0
    fm.@show_highlight.should be_true
    fm.current_index.should eq 0 # Down preselects the first entry

    bar.close
    press bar, Tput::Key::Up
    bar.open_index.should eq 0
    fm.current_index.should eq 2 # Up preselects the last entry
  end

  it "opens a submenu on Right with its first child selected" do
    s = headless_screen(80, 24)
    bar, fm = nav_bar(s)
    bar.open 0
    fm.select_last_action # highlight "Recent"

    press fm, Tput::Key::Right
    child = fm.@submenu_open
    child.nil?.should be_false
    child.try(&.@show_highlight).should be_true
    child.try(&.current_index).should eq 0 # "old-1"
  end

  it "opens a submenu on Enter or Space exactly like Right — first child selected" do
    s = headless_screen(80, 24)
    bar, fm = nav_bar(s)
    bar.open 0
    fm.select_last_action # highlight "Recent"

    press fm, Tput::Key::Enter
    child = fm.@submenu_open
    child.nil?.should be_false
    child.try(&.@show_highlight).should be_true
    child.try(&.current_index).should eq 0 # "old-1", like Right

    fm.close_submenu
    fm.handle_key_press Crysterm::Event::KeyPress.new(' ') # Space: identical
    child = fm.@submenu_open
    child.nil?.should be_false
    child.try(&.@show_highlight).should be_true
    child.try(&.current_index).should eq 0
  end

  it "moves to the next top-level menu on Right from a leaf, at any depth" do
    s = headless_screen(80, 24)
    bar, fm = nav_bar(s)
    bar.open 0
    fm.select_last_action
    press fm, Tput::Key::Right # into the "Recent" submenu
    child = fm.@submenu_open.not_nil!

    press child, Tput::Key::Right # "old-1" is a leaf: File -> Edit
    bar.open_index.should eq 1
    bar.menus[1].@show_highlight.should be_true # keyboard switch preselects

    press bar.menus[1], Tput::Key::Right # "Cut" is a leaf: Edit -> Help
    bar.open_index.should eq 2
    press bar.menus[2], Tput::Key::Right # wraps past the last title
    bar.open_index.should eq 0
  end

  it "closes one submenu level per Left, then moves to the previous menu" do
    s = headless_screen(80, 24)
    bar, fm = nav_bar(s)
    bar.open 0
    fm.select_last_action
    press fm, Tput::Key::Right
    child = fm.@submenu_open.not_nil!

    press child, Tput::Key::Left # first Left: only the submenu closes
    fm.@submenu_open.nil?.should be_true
    bar.open_index.should eq 0

    press fm, Tput::Key::Left # next Left: previous title, wrapping backward
    bar.open_index.should eq 2
  end
end
