require "./spec_helper"

include Crysterm

# Regression specs for the Calendar navigation-bar drop-downs.
#
#  BUG A (src/widget/menu.cr `#fit_width`/`#size_rows`): a scrolling `Menu`
#     reserves a right-edge column for its vertical scroll bar
#     (`content_margin_x`), but `fit_width` didn't add it and `size_rows` laid
#     rows across the full `awidth - ihorizontal`. The widest row was then one column
#     too wide for the drawable area and word-wrapped onto a clipped second line,
#     so every row rendered blank (only the gutter showed) — the Calendar's
#     ±100-year drop-down opened "invisible" even though scrolling/clicking still
#     worked. The month menu (no overflow, no scroll bar) was unaffected.
#
#  BUG B (src/widget/calendar.cr `#open_month_menu`): the month drop-down listed
#     bare month names; it now prefixes each with its zero-padded number
#     ("01: January" … "12: December") to match the numeric day/year fields.

private def cnd_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def cnd_row_text(s, y, x0, x1) : String
  String.build { |io| (x0...x1).each { |x| io << s.lines[y][x].char } }
end

private def cnd_open_calendar(s)
  cal = Crysterm::Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
    date: Time.local(2024, 1, 15)
  s._render
  cal
end

describe "Calendar year drop-down visibility (bug A)" do
  it "renders the scrolled year rows instead of blank rows" do
    s = cnd_screen
    cal = cnd_open_calendar s
    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop

    # Click the year field to open its ±100-year drop-down.
    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + cal.@nav_year_range.begin, ay)
    s._render

    ym = cal.year_menu.not_nil!
    # Overflowing list -> a vertical scroll bar is reserved.
    ym.content_margin_x.should be > 0

    # The shown year (2024) must actually be painted somewhere in the menu's rows,
    # not swallowed by a wrapped/clipped item. (Before the fix every row was blank.)
    x0 = ym.aleft
    x1 = ym.aleft + ym.awidth
    rows = (ym.atop...(ym.atop + ym.aheight)).map { |y| cnd_row_text s, y, x0, x1 }
    rows.any?(&.includes?("2024")).should be_true
    # A nearby year is present too, confirming the whole list renders (not just one).
    rows.any?(&.includes?("2023")).should be_true
  end
end

describe "Calendar month drop-down numbering (bug B)" do
  it "prefixes each month with its zero-padded number" do
    s = cnd_screen
    cal = cnd_open_calendar s
    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop

    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + cal.@nav_month_range.begin, ay)
    s._render

    mm = cal.month_menu.not_nil!
    texts = mm.@ritems.map { |r| mm.clean_tags r }
    texts[0].should contain "01: January"
    texts[8].should contain "09: September"
    texts[11].should contain "12: December"

    # Selecting an entry still pages to the right month.
    x0 = mm.aleft
    x1 = mm.aleft + mm.awidth
    rows = (mm.atop...(mm.atop + mm.aheight)).map { |y| cnd_row_text s, y, x0, x1 }
    rows.any?(&.includes?("03: March")).should be_true
  end

  it "still pages to the picked month when an entry is activated" do
    s = cnd_screen
    cal = cnd_open_calendar s
    cal.month_shown.should eq 1

    cal.@month_menu.try &.destroy
    # Reopen and activate the March row directly through the menu action.
    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop
    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + cal.@nav_month_range.begin, ay)
    s._render
    mm = cal.month_menu.not_nil!
    mm.actions[2].activate # "03: March"
    cal.month_shown.should eq 3
  end
end
