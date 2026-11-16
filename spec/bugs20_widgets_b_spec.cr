require "./spec_helper"

include Crysterm

# `DateTimeEdit#date`/`#date=`/`#time`/`#time=` work through the virtual
# `#date_time` accessors, so `DateEdit`/`TimeEdit` (which keep their value in
# their own ivar) read and keep their actual value.

describe "DateTimeEdit date/time accessors on DateEdit/TimeEdit" do
  it "TimeEdit#time=(Span) keeps the edit's own date" do
    s = headless_screen(60, 24)
    te = Widget::TimeEdit.new parent: s, time: Time.utc(2000, 1, 2, 10, 0, 0)

    te.time = 5.hours + 6.minutes

    te.time.should eq Time.utc(2000, 1, 2, 5, 6, 0)
  end

  it "TimeEdit#date= keeps the edit's own time of day" do
    s = headless_screen(60, 24)
    te = Widget::TimeEdit.new parent: s, time: Time.utc(2000, 1, 2, 10, 0, 0)

    te.date = Time.utc(2001, 2, 3)

    te.time.should eq Time.utc(2001, 2, 3, 10, 0, 0)
    te.date.should eq Time.utc(2001, 2, 3)
  end

  it "DateEdit#time=(Span) leaves the date alone" do
    s = headless_screen(60, 24)
    de = Widget::DateEdit.new parent: s, date: Time.utc(2020, 1, 15)
    changed = [] of Time
    de.on(Crysterm::Event::DateChanged) { |e| changed << e.date }

    de.time = 3.hours

    de.date.should eq Time.utc(2020, 1, 15)
    changed.should be_empty
  end
end

# `DateTimeEdit#date=`/`#time=` rebuild the instant from wall-clock
# components, so a DST transition on that day does not shift the time.

describe "DateTimeEdit date/time setters across DST" do
  it "keeps the wall-clock time on a spring-forward day" do
    ny = begin
      Time::Location.load("America/New_York")
    rescue
      nil
    end
    pending! "tzdata unavailable" unless ny
    s = headless_screen(60, 24)
    dte = Widget::DateTimeEdit.new parent: s, date_time: Time.local(2026, 3, 8, 10, 0, 0, location: ny)

    dte.time = 10.hours
    dte.date_time.hour.should eq 10

    dte.date = Time.local(2026, 3, 8, location: ny)
    dte.date_time.hour.should eq 10
    dte.date_time.day.should eq 8
  end
end

# The ISO week gutter computes each row's Thursday directly, so the first
# grid row of January 1 (whose leading cells fall in year 0) renders.

describe "Calendar ISO week numbers at the start of the Time range" do
  it "renders January of year 1 with week numbers" do
    s = headless_screen(60, 24)
    cal = Widget::Calendar.new parent: s, width: 30, height: 10
    cal.minimum_date = Time.utc(1, 1, 1)
    cal.vertical_header_format = Widget::Calendar::VerticalHeaderFormat::ISOWeekNumbers

    cal.selected_date = Time.utc(1, 1, 1)

    cal.year_shown.should eq 1
    cal.month_shown.should eq 1
  end
end

# A combining (zero-width) char in a GaugeList label takes an array slot but
# no column; the row reserves the slot so the percentage is not cut off.

describe "GaugeList label with combining marks" do
  it "keeps the whole percentage on the row" do
    s = headless_screen(60, 10)
    s.full_unicode = true
    pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
    gl = Widget::GaugeList.new parent: s, top: 0, left: 0, width: 20, height: 1
    gl.add_item "ééé", 64

    s.repaint

    gl.content.should contain "64%"
  end
end

# ProgressBar range arithmetic runs in Int64, so a range wider than
# `Int32::MAX` neither overflows nor skews the percentage, and a key step at
# an `Int32` bound saturates.

describe "ProgressBar wide Int32 ranges" do
  it "computes the percentage without overflow" do
    s = headless_screen(60, 10)
    pb = Widget::ProgressBar.new parent: s, width: 20, height: 1,
      minimum: -2_000_000_000, maximum: 2_000_000_000, value: 1_000_000_000

    pb.percent.should eq 75
    s.repaint # must not raise
  end

  it "maps a percentage back onto the full range" do
    s = headless_screen(60, 10)
    pb = Widget::ProgressBar.new parent: s, width: 20, height: 1,
      minimum: -2_000_000_000, maximum: 2_000_000_000

    pb.percent = 25
    pb.value.should eq(-1_000_000_000)
    pb.percent = 100
    pb.value.should eq 2_000_000_000
  end

  it "saturates a key step at the Int32 bounds" do
    s = headless_screen(60, 10)
    pb = Widget::ProgressBar.new parent: s, width: 20, height: 1, keys: true,
      minimum: Int32::MIN, maximum: Int32::MAX, value: Int32::MIN

    pb.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Left)
    pb.value.should eq Int32::MIN

    pb.value = Int32::MAX
    pb.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::Right)
    pb.value.should eq Int32::MAX
  end
end

# A negative `page_step` that cancels the value span leaves no thumb ratio to
# take; the thumb fills the track instead of the render raising.

describe "ScrollBar thumb with a span-cancelling page_step" do
  it "renders" do
    s = headless_screen(20, 12)
    sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 10, maximum: 10
    sb.page_step = -10
    s.repaint # must not raise
  end
end
