require "./spec_helper"

include Crysterm

describe "Calendar#day_decorator" do
  it "lets the host rewrite each day cell and keeps the selection highlight around it" do
    s = headless_screen(40, 12)
    cal = Crysterm::Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 10,
      date: Time.utc(2026, 10, 9)
    cal.highlight_today = false
    cal.day_decorator = ->(day : Time, cell : String) do
      day.day == 15 ? "{red-fg}#{cell}{/red-fg}" : cell
    end

    content = cal.content
    content.should contain("{red-fg}15{/red-fg}")
    content.should contain("{reverse} 9{/reverse}")
    content.should_not contain("{red-fg} 9")

    cal.day_decorator = ->(day : Time, cell : String) { day.day == 9 ? "{bold}#{cell}{/bold}" : cell }
    cal.content.should contain("{reverse}{bold} 9{/bold}{/reverse}")

    cal.day_decorator = nil
    cal.content.should_not contain("{bold}")
  ensure
    s.try &.destroy
  end

  it "hands the decorator the shown month's dates when paging" do
    s = headless_screen(40, 12)
    cal = Crysterm::Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 10,
      date: Time.utc(2026, 10, 9)
    cal.highlight_today = false
    seen = [] of Time
    cal.day_decorator = ->(day : Time, cell : String) { seen << day; cell }
    seen.map(&.month).uniq!.should eq [10]
    seen.size.should eq 31

    seen.clear
    cal.show_next_month
    seen.map(&.month).uniq!.should eq [11]
    seen.size.should eq 30
  ensure
    s.try &.destroy
  end
end
