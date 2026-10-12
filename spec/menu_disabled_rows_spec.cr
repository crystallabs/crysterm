require "./spec_helper"

include Crysterm

# A disabled action's menu row is drawn in the theme's disabled look (Qt's
# `QPalette::Disabled` text): the theme's `Menu::item:disabled` rule, or a Qt
# theme's own `QMenu::item:disabled`. The whole row takes it — check mark,
# label and shortcut column alike — and it follows `Action#enabled=` while the
# menu is open. The row is not put in the disabled widget state, so it still
# highlights on hover.

private def with_theme(theme : Crysterm::CSS::Theme?, &)
  saved = Crysterm::CSS.theme
  Crysterm::CSS.theme = theme
  yield
ensure
  Crysterm::CSS.theme = saved
end

# An open menu of three entries, the middle one disabled; the menu sits at
# (0, 0) so its first row is screen row 1 (below the top border).
private def disabled_menu(s)
  menu = Widget::Menu.new parent: s, top: 0, left: 0, width: 30, height: 5
  open = Action.new "Open", shortcut: Tput::Key::CtrlO
  next_file = Action.new "Next File", shortcut: Tput::Key::CtrlN
  next_file.enabled = false
  quit = Action.new "Quit", shortcut: Tput::Key::CtrlQ
  menu << open << next_file << quit
  s.repaint
  {menu, next_file}
end

# The foreground of row *y*'s label (column 2, past the border and padding)
# and of its last shortcut cell.
private def row_fgs(s, menu, y)
  {cell_fg(s, 2, y), cell_fg(s, menu.awidth - 3, y)}
end

describe "Menu disabled rows" do
  {Crysterm::CSS::Theme.dark, Crysterm::CSS::Theme.light, Crysterm::CSS::Theme.builtin("breeze-dark").not_nil!}.each do |theme|
    it "draws a disabled entry, its shortcut too, in the #{theme.name} theme's disabled color" do
      s = headless_screen(60, 10)
      with_theme(theme) do
        menu, _ = disabled_menu s
        enabled = row_fgs(s, menu, 1)
        disabled = row_fgs(s, menu, 2)
        disabled[0].should_not eq enabled[0]
        disabled[1].should eq disabled[0]
        row_fgs(s, menu, 3).should eq enabled
      end
    end
  end

  it "takes the enabled look back when the action is enabled while the menu is open, and loses it again" do
    s = headless_screen(60, 10)
    with_theme(Crysterm::CSS::Theme.dark) do
      menu, next_file = disabled_menu s
      enabled = row_fgs(s, menu, 1)
      greyed = row_fgs(s, menu, 2)
      next_file.enabled = true
      s.repaint
      row_fgs(s, menu, 2).should eq enabled
      next_file.enabled = false
      s.repaint
      row_fgs(s, menu, 2).should eq greyed
    end
  end

  it "still highlights a disabled entry, keeping the disabled foreground on the selection" do
    s = headless_screen(60, 10)
    with_theme(Crysterm::CSS::Theme.dark) do
      menu, _ = disabled_menu s
      greyed = cell_fg(s, 2, 2)
      plain_bg = cell_bg(s, 2, 2)
      menu.hover_item 1
      s.repaint
      menu.selected_action.try(&.text).should eq "Next File"
      cell_bg(s, 2, 2).should_not eq plain_bg
      cell_fg(s, 2, 2).should eq greyed
      menu.item_boxes[1].disabled?.should be_false
    end
  end
end
