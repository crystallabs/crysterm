require "./spec_helper"

include Crysterm

private def tb_bg(s, x, y) : Int32
  Attr.unpack_color(Attr.bg(s.cell_rows[y][x].attr))
end

private def tb_fg(s, x, y) : Int32
  Attr.unpack_color(Attr.fg(s.cell_rows[y][x].attr))
end

# Installs *theme* for the block — the window exists already, so this
# assignment is what sets its default stylesheet — restoring the previous
# theme afterwards.
private def with_theme(theme : Crysterm::CSS::Theme?, &)
  saved = Crysterm::CSS.theme
  Crysterm::CSS.theme = theme
  yield
ensure
  Crysterm::CSS.theme = saved
end

# `background-color: transparent` on a widget means, as in CSS and Qt, that it
# paints no background of its own and the parent's shows through. Crysterm's
# fill writes every cell of a widget's box, so the cascade's inheritance pass
# resolves a transparent background to the parent's computed one; only a
# widget with nothing behind it keeps the terminal default.
describe "CSS background-color: transparent" do
  it "lets the parent's background show through a transparent child" do
    s = headless_screen(20, 6)
    s.stylesheet = ".Parent { background-color: #336699; } " \
                   ".Child { background-color: transparent; color: #ffffff; }"
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6
    parent.add_css_class "Parent"
    child = Widget::Box.new parent: parent, top: 1, left: 1, width: 10, height: 2, content: "hi"
    child.add_css_class "Child"
    s.repaint

    child.style.bg.should eq 0x336699
    tb_bg(s, 1, 1).should eq 0x336699 # a text cell
    tb_bg(s, 8, 2).should eq 0x336699 # an empty fill cell
    tb_fg(s, 1, 1).should eq 0xffffff # the child's own text color stays
    tb_bg(s, 15, 4).should eq 0x336699
  end

  it "follows a transparent chain to the first painted ancestor" do
    s = headless_screen(20, 6)
    s.stylesheet = ".Outer { background-color: #aa5500; } " \
                   ".Mid, .Inner { background-color: transparent; }"
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6
    outer.add_css_class "Outer"
    mid = Widget::Box.new parent: outer, top: 0, left: 0, width: 18, height: 5
    mid.add_css_class "Mid"
    inner = Widget::Box.new parent: mid, top: 1, left: 1, width: 8, height: 2, content: "x"
    inner.add_css_class "Inner"
    s.repaint

    mid.style.bg.should eq 0xaa5500
    inner.style.bg.should eq 0xaa5500
    tb_bg(s, 1, 1).should eq 0xaa5500
  end

  it "keeps the terminal default on a transparent widget with nothing behind it" do
    s = headless_screen(20, 6)
    s.stylesheet = ".Top { background-color: transparent; color: #ffffff; }"
    top = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6, content: "x"
    top.add_css_class "Top"
    s.repaint

    top.style.bg.should eq -1
    tb_bg(s, 0, 0).should eq -1
    tb_bg(s, 10, 3).should eq -1
  end

  it "leaves a child's own background color alone" do
    s = headless_screen(20, 6)
    s.stylesheet = ".Parent { background-color: #336699; } .Child { background-color: #112233; }"
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6
    parent.add_css_class "Parent"
    child = Widget::Box.new parent: parent, top: 1, left: 1, width: 10, height: 2
    child.add_css_class "Child"
    s.repaint

    child.style.bg.should eq 0x112233
    tb_bg(s, 2, 1).should eq 0x112233
  end

  # Breeze Light's `QMenu::item { background: transparent }` rows: before, every
  # row not highlighted painted the terminal default under the theme's dark
  # text — unreadable on a dark terminal. The rows now paint the menu's own
  # surface, in a submenu as in the top-level menu, while the highlighted row
  # keeps `QMenu::item:selected`'s accent.
  it "paints a built-in Qt theme's transparent menu rows in the menu's background" do
    s = headless_screen(60, 16)
    with_theme(Crysterm::CSS::Theme.builtin("breeze-light")) do
      menu = Widget::Menu.new parent: s
      menu.add_action("&New") { }
      menu.add_submenu "&Export", [Action.new("&Pdf"), Action.new("&Html")]
      menu.add_action("&Quit") { }
      menu.popup 2, 1
      s.repaint
      menu.current_index = 1
      menu.hover_item 1 # opens the submenu, and reveals the highlight
      s.repaint

      surface = menu.style.bg.not_nil!
      surface.should eq 0xeff0f1

      rows = menu.item_boxes
      rows.size.should eq 3
      plain = rows[0]
      plain.style.bg.should eq surface
      lp = plain.lpos.not_nil!
      (lp.xi...lp.xl).each { |x| tb_bg(s, x, lp.yi).should eq surface }
      tb_fg(s, lp.xi + 1, lp.yi).should eq 0x31363b # the theme's text, legible on it

      selected = rows[1].lpos.not_nil!
      tb_bg(s, selected.xi + 1, selected.yi).should eq 0x33a4df # QMenu::item:selected

      sub = menu.@submenu_open.not_nil!
      sub.style.bg.should eq surface
      sub_row = sub.item_boxes[1]
      sub_row.style.bg.should eq surface
      slp = sub_row.lpos.not_nil!
      (slp.xi...slp.xl).each { |x| tb_bg(s, x, slp.yi).should eq surface }
      tb_fg(s, slp.xi + 1, slp.yi).should eq 0x31363b
    end
  end
end
