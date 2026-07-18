require "./spec_helper"

include Crysterm

# Regression (src/widget/date_edit.cr `#grab_contains?`,
# src/widget/calendar.cr `#nav_popup_contains?`):
#
# `DateEdit` floats a `Calendar` as its pop-up and dismisses it on a press
# outside its modal grab region (the field plus the calendar's rectangle). But
# the calendar's own month/year nav dropdowns are window-level `Menu`s that
# routinely overhang the calendar — the ±100-year list especially, and the
# 12-row month list when the field sits low. Picking a month/year row that fell
# below the calendar's rectangle read as a click-away and tore the *whole*
# calendar down, when only the dropdown should close (leaving the user back on
# the open calendar). `#grab_contains?` now also counts the calendar's open nav
# dropdowns as "inside".

private def denp_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80, height: 24,
    default_quit_keys: false)
end

private def denp_down(s, x, y)
  s.dispatch_mouse Tput::Mouse::Event.new(
    Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, x, y, source: :test)
  s._render
end

private def denp_open(s)
  de = Crysterm::Widget::DateEdit.new parent: s, top: 5, left: 10, width: 12, height: 1,
    date: Time.utc(2026, 7, 4)
  de.focus
  s._render
  de.show_popup
  s._render
  {de, de.@popup.not_nil!}
end

# Lowest actually-rendered row of a menu (the one most likely to overhang the
# calendar), as an absolute (x, y).
private def denp_lowest_row(menu)
  lp = menu.@items.compact_map(&.@lpos).max_by(&.yi)
  {lp.xi, lp.yi}
end

describe "DateEdit keeps the calendar open when picking a nav-dropdown row that overhangs it" do
  it "closes only the month dropdown, not the calendar" do
    s = denp_screen
    de, cal = denp_open s
    de.open?.should be_true

    # Open the month dropdown from the nav bar.
    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop
    denp_down s, ax + cal.@nav_month_range.begin, ay
    menu = cal.month_menu.not_nil!

    # The month list overhangs the calendar's own rectangle.
    mx, my = denp_lowest_row menu
    my.should be > (cal.atop + cal.aheight - 1)

    denp_down s, mx, my
    de.open?.should be_true                           # calendar still open …
    cal.month_menu.try(&.visible?).should_not eq true # … only the dropdown closed
    cal.month_shown.should eq 12                      # and the pick took effect
  end

  it "closes only the year dropdown, not the calendar" do
    s = denp_screen
    de, cal = denp_open s
    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop
    denp_down s, ax + cal.@nav_year_range.begin, ay
    menu = cal.year_menu.not_nil!

    yx, yy = denp_lowest_row menu
    yy.should be > (cal.atop + cal.aheight - 1)

    denp_down s, yx, yy
    de.open?.should be_true
    cal.year_menu.try(&.visible?).should_not eq true
  end

  it "renders the year dropdown's scroll handle the same size as a Completer's (not a 1-cell nub)" do
    s = denp_screen
    _de, cal = denp_open s
    denp_down s, cal.aleft + cal.ileft + cal.@nav_year_range.begin, cal.atop + cal.itop
    menu = cal.year_menu.not_nil!
    sb = menu.scrollbar_widget.not_nil!
    sb.visible?.should be_true

    # Purely proportional, a ±100-year list would collapse the handle to 1 cell;
    # the shared item-view minimum floors it to a real block, matching a
    # `Completer`/`List` drop-down.
    sb.min_thumb.should eq Crysterm::Mixin::ItemView::ITEM_VIEW_MIN_THUMB
    x = sb.aleft
    thumb = (sb.atop...(sb.atop + sb.aheight)).count { |y| s.lines[y][x].char == sb.thumb_char }
    thumb.should eq Crysterm::Mixin::ItemView::ITEM_VIEW_MIN_THUMB
  end

  it "still dismisses the calendar on a press truly outside it and its dropdowns" do
    s = denp_screen
    de, cal = denp_open s
    denp_down s, cal.aleft + cal.ileft + cal.@nav_month_range.begin, cal.atop + cal.itop
    cal.month_menu.not_nil!

    # A press far from the field, calendar, and open dropdown still closes it.
    denp_down s, 70, 1
    de.open?.should be_false
  end
end
