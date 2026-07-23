require "./spec_helper"

include Crysterm

# Regression specs for BUGS18 (layout coords vs painted lpos, plus the
# headless `Time.local` fallback):
#
#   B18-02  WidgetCursorAnchor#cursor_pos — the anchor row must map through
#           the RENDERED position (`lpos.yi + itop - lpos.base`), not layout
#           `atop`, so a popup anchored at the shell cursor lands on the
#           *visible* cursor inside a scrolled/clipped container (the same
#           mapping as Terminal#draw / the B17-34 on_mouse fix).
#   B18-40  MenuBar#open / ToolButton#show_menu — pop-up menus must anchor on
#           the owner's painted rect (`Widget#painted_rect`), not layout
#           coords, inside a scrolled container (sibling of fixed B16-31).
#   B18-101 Completer#position — same defect for the drop-down list of a
#           LineEdit inside a scrolled container.
#   B18-104 SectionedField#section_from_columns — the pointer x is a painted
#           screen coordinate, so it must resolve against the painted origin,
#           not layout `aleft` (a MoveWidget-translated ancestor diverges the
#           two horizontally).
#   B18-48  SectionedField.build_time — the shared `Time.local`-with-UTC-
#           fallback builder behind step_time_field / Calendar#local_date, so
#           stepping a date/time editor cannot raise in a headless context.

private def b18_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# ── B18-02: WidgetCursorAnchor maps the cursor through the painted rect. ──
describe "BUGS18 B18-02: WidgetCursorAnchor in a scrolled container" do
  it "anchors on the painted cursor row, not offset by the scroll base" do
    s = b18_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 10, scrollable: true
    term = Crysterm::Widget::Terminal.new(
      parent: outer, top: 4, left: 2, width: 30, height: 5,
      handler: ->(_data : String) { nil })
    # Tall spacer below so the container has a real scroll extent.
    Widget::Box.new parent: outer, top: 20, left: 0, width: 1, height: 20
    s.repaint

    k = 3
    outer.scroll_to k, true
    s.repaint

    lp = term.lpos.not_nil!
    # Sanity: the terminal is painted k rows above its layout position, fully
    # visible (no top clipping folded into base).
    lp.yi.should eq term.atop - k
    lp.base.should eq 0

    em = term.emulator.not_nil!
    em.feed "\e[2;4H" # cursor to emulator row 1, col 3 (0-based)
    em.cursor_y.should eq 1
    em.cursor_x.should eq 3

    anchor = Crysterm::WidgetCursorAnchor.new(term)
    # Pre-fix the row came out `atop + itop + cursor_y` — k rows below the
    # visibly painted cursor.
    anchor.cursor_row.should eq lp.yi + term.itop + em.cursor_y
    anchor.cursor_col.should eq term.aleft + term.ileft + em.cursor_x
  ensure
    term.try &.kill
    s.try &.destroy
  end

  it "subtracts the clipped-top base, matching where #draw paints the cursor" do
    s = b18_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 8, scrollable: true
    term = Crysterm::Widget::Terminal.new(
      parent: outer, top: 0, left: 0, width: 10, height: 6,
      handler: ->(_data : String) { nil })
    Widget::Box.new parent: outer, top: 6, left: 0, width: 1, height: 30
    s.repaint

    outer.scroll_to 3, true
    s.repaint

    lp = term.lpos.not_nil!
    lp.base.should be > 0 # the terminal's top `base` rows are clipped

    em = term.emulator.not_nil!
    em.feed "\e[5;1H" # cursor to emulator row 4 — inside the visible part
    em.cursor_y.should eq 4

    anchor = Crysterm::WidgetCursorAnchor.new(term)
    # Emulator row `base` is the one painted at the clip edge `lp.yi`, so the
    # cursor's painted row is `lp.yi + itop + cursor_y - base`.
    anchor.cursor_row.should eq lp.yi + term.itop + em.cursor_y - lp.base
  ensure
    term.try &.kill
    s.try &.destroy
  end
end

# ── B18-40: MenuBar / ToolButton pop-ups anchor on the painted rect. ──
describe "BUGS18 B18-40: MenuBar#open in a scrolled container" do
  it "drops the menu directly below the painted bar, not its layout row" do
    s = b18_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 10, scrollable: true
    bar = Widget::MenuBar.new parent: outer, top: 5, left: 0, width: 30, height: 1
    file = bar.add_menu "File"
    file.add_action("New") { }
    Widget::Box.new parent: outer, top: 20, left: 0, width: 1, height: 20
    s.repaint

    k = 3
    outer.scroll_to k, true
    s.repaint

    lp = bar.lpos.not_nil!
    lp.yi.should eq bar.atop - k # painted above the layout row

    bar.open 0
    menu = bar.menus[0]
    menu.visible?.should be_true
    # Pre-fix the menu dropped at `atop + aheight`, k rows below the visible bar.
    menu.atop.should eq lp.yl
    # The title column comes from the item box's painted rect (identical to its
    # layout aleft here — no horizontal scroll). The item box has no own `lpos`
    # once the tall spacer scrolls it (its render folds into the bar), so anchor
    # on `#painted_rect`, exactly what `MenuBar#title_x` reads.
    menu.aleft.should eq bar.item_boxes[0].painted_rect[0]
  end
end

describe "BUGS18 B18-40: ToolButton#show_menu in a scrolled container" do
  it "drops the menu directly below the painted button, not its layout row" do
    s = b18_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 10, scrollable: true
    m = Widget::Menu.new parent: s
    m.add_action("One") { }
    m.hide
    tb = Widget::ToolButton.new parent: outer, top: 6, left: 2, content: "Tools", menu: m
    Widget::Box.new parent: outer, top: 20, left: 0, width: 1, height: 20
    s.repaint

    k = 4
    outer.scroll_to k, true
    s.repaint

    lp = tb.lpos.not_nil!
    lp.yi.should eq tb.atop - k

    tb.show_menu
    m.visible?.should be_true
    # Pre-fix the menu popped at layout `atop + aheight`, k rows below the
    # visibly painted button.
    m.atop.should eq lp.yl
    m.aleft.should eq lp.xi
  end
end

# ── B18-101: Completer drop-down anchors on the painted rect. ──
describe "BUGS18 B18-101: Completer drop-down in a scrolled container" do
  it "opens flush below the painted field, not its layout row" do
    s = b18_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 12, scrollable: true
    box = Widget::LineEdit.new parent: outer, top: 8, left: 5, width: 18, height: 1
    completer = Crysterm::Completer.new %w[Crystal Ruby Rust]
    completer.attach box
    Widget::Box.new parent: outer, top: 30, left: 0, width: 1, height: 20
    box.focus
    s.repaint

    k = 5
    outer.scroll_to k, true
    s.repaint

    lp = box.lpos.not_nil!
    lp.yi.should eq box.atop - k

    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
    s.repaint

    pop = completer.@popup.not_nil!
    pop.visible?.should be_true
    # Pre-fix the list opened at layout `atop + aheight`, k rows below the
    # visible field, detached from it.
    pop.atop.should eq lp.yl
    pop.aleft.should eq lp.xi
  end
end

# ── B18-104: section hit-test resolves against the painted origin. ──
describe "BUGS18 B18-104: SectionedField click mapping under a moved painted rect" do
  it "selects the section under the painted pointer when MoveWidget shifted the field" do
    s = b18_screen
    # The box overflows the 80-col window's right edge, so MoveWidget
    # translates its painted rect left: painted xi 60, layout aleft 75.
    box = Widget::Box.new parent: s, top: 2, left: 75, width: 20, height: 3,
      overflow: Crysterm::Overflow::MoveWidget
    te = Widget::TimeEdit.new parent: box, top: 0, left: 0, width: 8, height: 1,
      time: Time.utc(2020, 1, 1, 10, 20, 30)
    s.repaint # synchronous frame; `#render` only rings the (async) doorbell

    lp = te.lpos.not_nil!
    lp.xi.should eq 60
    te.aleft.should eq 75

    # Opens on the hour section (highlighted reverse).
    te.content.should eq "{reverse}10{/reverse}:20:30"

    # Click the painted minute column (content col 3). Pre-fix the column was
    # resolved against layout aleft, giving col 3 - 15 < 0 → silent no-op.
    s.dispatch_mouse ::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left,
      lp.xi + 3, lp.yi)
    te.content.should eq "10:{reverse}20{/reverse}:30"
  end
end

# ── B18-48: shared headless-safe Time builder on the step path. ──
describe "BUGS18 B18-48: SectionedField.build_time" do
  it "builds the requested wall-clock components" do
    t = Mixin::SectionedField.build_time(2020, 2, 29, 12, 30, 45)
    {t.year, t.month, t.day, t.hour, t.minute, t.second}
      .should eq({2020, 2, 29, 12, 30, 45})
  end

  it "defaults h/mi/s to 0 (Calendar#local_date signature)" do
    t = Mixin::SectionedField.build_time(2021, 3, 4)
    {t.year, t.month, t.day, t.hour, t.minute, t.second}
      .should eq({2021, 3, 4, 0, 0, 0})
  end

  it "steps a TimeEdit section through the guarded builder" do
    s = b18_screen
    te = Widget::TimeEdit.new parent: s, top: 0, left: 0, width: 8, height: 1,
      time: Time.utc(2020, 1, 1, 10, 20, 30)
    s.render
    te.focus

    te.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Up)
    te.time.hour.should eq 11
    te.time.minute.should eq 20
  end
end
