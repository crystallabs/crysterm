require "./spec_helper"

include Crysterm

# Above the ASCII tier a menu's check column draws one glyph per mark —
# `☑`/`☐`, and `◉`/`○` for a member of an exclusive `ActionGroup` — two cells
# with the gap before the label, where the ASCII tier keeps the composed
# `[x] `/`[ ] ` of four.

private def check_menu(s)
  menu = Widget::Menu.new parent: s, top: 0, left: 0, width: 24, height: 7
  wrap = Action.new "Wrap", checkable: true, checked: true
  ruler = Action.new "Ruler", checkable: true
  plain = Action.new "Reload"
  group = ActionGroup.new
  light = Action.new "Light"
  dark = Action.new "Dark"
  group.add_action light
  group.add_action dark
  dark.checked = true
  menu << wrap << ruler << plain << light << dark
  s.repaint
  menu
end

# The row texts, label column onward, without the trailing fill.
private def rows(menu)
  menu.item_boxes.map &.content.rstrip
end

describe "Menu check marks" do
  it "draws one glyph per mark, radio marks for an exclusive group, above the ASCII tier" do
    s = headless_screen(40, 10)
    menu = check_menu s
    rows(menu).should eq ["☑ Wrap", "☐ Ruler", "  Reload", "○ Light", "◉ Dark"]
  end

  it "keeps the composed bracketed marks at the ASCII tier" do
    s = headless_screen(40, 10)
    s.glyph_tier = Glyphs::Tier::Ascii
    menu = check_menu s
    rows(menu).should eq ["[x] Wrap", "[ ] Ruler", "    Reload", "[ ] Light", "[x] Dark"]
  end

  it "follows a check change and a group's exclusivity while shown" do
    s = headless_screen(40, 10)
    menu = check_menu s
    wrap = menu.actions[0]
    wrap.checked = false
    s.repaint
    rows(menu)[0].should eq "☐ Wrap"
    menu.actions[4].action_group.not_nil!.exclusive = false
    s.repaint
    rows(menu)[3..].should eq ["☐ Light", "☑ Dark"]
  end

  it "has no check column when nothing is checkable" do
    s = headless_screen(40, 10)
    menu = Widget::Menu.new parent: s, top: 0, left: 0, width: 24, height: 4
    menu << Action.new("Open") << Action.new("Quit")
    s.repaint
    rows(menu).should eq ["Open", "Quit"]
  end

  it "measures each one-glyph mark one column wide" do
    {Glyphs::Role::CheckMarkChecked, Glyphs::Role::CheckMarkUnchecked,
     Glyphs::Role::RadioMarkChecked, Glyphs::Role::RadioMarkUnchecked}.each do |role|
      Crysterm::Unicode.width(Glyphs.str(role, Glyphs::Tier::Unicode)).should eq 1
    end
  end
end
