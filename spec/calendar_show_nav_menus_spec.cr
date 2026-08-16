require "./spec_helper"

include Crysterm

# `Calendar#show_month_menu` / `#show_year_menu`: the programmatic counterpart
# of `ComboBox#show_popup`, opening the same nav-bar pop-ups a click on the
# month name / year field would (used by self-driving demos, e.g.
# tests/misc/widgets2.cr).

private def snm_calendar(s)
  cal = Crysterm::Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
    date: Time.utc(2026, 6, 1)
  s.repaint
  cal
end

describe "Calendar#show_month_menu / #show_year_menu" do
  it "opens the month menu on the shown month and dismisses cleanly" do
    s = headless_screen(80, 24)
    cal = snm_calendar s

    cal.show_month_menu
    mm = cal.month_menu.not_nil!
    mm.visible?.should be_true
    mm.count.should eq 12
    mm.current_index.should eq 5 # June

    mm.hover_item 6 # walk the highlight, as the demo does
    mm.current_index.should eq 6

    mm.hide_popup
    mm.visible?.should be_false
  end

  it "opens the year menu scrolled to the shown year" do
    s = headless_screen(80, 24)
    cal = snm_calendar s

    cal.show_year_menu
    ym = cal.year_menu.not_nil!
    ym.visible?.should be_true
    ym.count.should eq 2 * Crysterm::Widget::Calendar::YEAR_MENU_RADIUS + 1
    ym.current_index.should eq Crysterm::Widget::Calendar::YEAR_MENU_RADIUS # 2026
  end

  it "opening one nav dropdown closes the other" do
    s = headless_screen(80, 24)
    cal = snm_calendar s

    cal.show_month_menu
    cal.show_year_menu
    cal.month_menu.not_nil!.visible?.should be_false
    cal.year_menu.not_nil!.visible?.should be_true
  end
end
