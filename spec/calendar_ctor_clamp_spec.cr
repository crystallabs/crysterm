require "./spec_helper"

include Crysterm

# `Calendar#initialize` seeds `@date`/`@shown_year`/`@shown_month` with plain
# values before `super`, then clamps the selection into
# `[minimum_date, maximum_date]` and re-derives the shown page once the base
# widget is fully constructed. These pin the observable contract of that
# ordering: an out-of-range constructor date lands on the bound, and the shown
# page always agrees with the (clamped) selection.

describe "Calendar constructor clamp and shown page" do
  it "clamps a date below the default minimum onto minimum_date and pages to it" do
    s = headless_screen(80, 24)
    cal = Crysterm::Widget::Calendar.new parent: s, date: Time.utc(1000, 6, 15)

    cal.selected_date.should eq cal.minimum_date
    cal.year_shown.should eq cal.minimum_date.year
    cal.month_shown.should eq cal.minimum_date.month
  end

  it "keeps an in-range date, truncated to the day, and shows its page" do
    s = headless_screen(80, 24)
    cal = Crysterm::Widget::Calendar.new parent: s, date: Time.utc(2030, 5, 17, 13, 45, 9)

    cal.selected_date.should eq Time.utc(2030, 5, 17)
    cal.year_shown.should eq 2030
    cal.month_shown.should eq 5
  end

  it "defaults to today's page when no date is given" do
    s = headless_screen(80, 24)
    cal = Crysterm::Widget::Calendar.new parent: s
    today = Crysterm::Mixin::SectionedField.default_today.at_beginning_of_day

    cal.selected_date.should eq today
    cal.year_shown.should eq today.year
    cal.month_shown.should eq today.month
  end
end
