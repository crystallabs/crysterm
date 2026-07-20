require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 wave-3 interactive-widget findings:
# B16-35, B16-36, B16-37.

private def headless_screen(w = 40, h = 10)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# B16-35 — the constructor accepted `checked: true` on a non-checkable button,
# creating a stuck state: `checked?` true while `#uncheck`/`#toggle` no-op on
# the `checkable?` guard, so no API could clear it.
describe "BUGS16 B16-35: checked: true requires checkable" do
  it "ignores checked: true on a non-checkable button" do
    s = headless_screen
    btn = Widget::Button.new parent: s, text: "Save", checked: true
    btn.checkable?.should be_false
    btn.checked?.should be_false
  ensure
    s.try &.destroy
  end

  it "honors checked: true on a checkable button" do
    s = headless_screen
    btn = Widget::Button.new parent: s, text: "Save", checkable: true, checked: true
    btn.checked?.should be_true
    btn.checked = false
    btn.checked?.should be_false
  ensure
    s.try &.destroy
  end
end

# B16-36 — DateEdit/TimeEdit inherited `date_time` accessors that tracked the
# parent's unused `@datetime` ivar: the setter emitted `Event::DateChanged`
# without changing the widget's value or display, and the getter returned the
# construction-time `Time.local`. They now delegate to `date`/`time`.
describe "BUGS16 B16-36: DateEdit/TimeEdit date_time delegation" do
  it "TimeEdit#date_time= updates the time and fires one DateChanged" do
    s = headless_screen
    te = Widget::TimeEdit.new parent: s, time: Time.local(2024, 1, 15, 10, 30, 0)
    events = [] of Time
    te.on(Crysterm::Event::DateChanged) { |e| events << e.date }

    v = Time.local(2030, 5, 1, 12, 0, 0)
    te.date_time = v
    te.time.should eq v
    te.date_time.should eq v
    events.should eq [v]

    te.date_time = v # no change: no event
    events.size.should eq 1
  ensure
    s.try &.destroy
  end

  it "DateEdit#date_time reflects the configured date (day-normalized)" do
    s = headless_screen
    de = Widget::DateEdit.new parent: s, date: Time.local(2024, 3, 10)
    de.date_time.should eq de.date

    v = Time.local(2031, 7, 4, 15, 45, 0)
    de.date_time = v
    de.date.should eq v.at_beginning_of_day
    de.date_time.should eq v.at_beginning_of_day
  ensure
    s.try &.destroy
  end
end

# B16-37 — the sparse tick walk's overflow guard `tv > @maximum - interval`
# itself underflowed Int32 when `maximum` sits within one tick interval of
# `Int32::MIN`, raising OverflowError inside render.
describe "BUGS16 B16-37: slider tick guard near Int32::MIN" do
  it "renders ticks for a range hugging Int32::MIN without raising" do
    s = headless_screen
    Widget::Slider.new parent: s, top: 0, left: 0, width: 30, height: 2,
      minimum: Int32::MIN, maximum: Int32::MIN + 5,
      tick_position: Widget::Slider::TickPosition::Below
    s._render # pre-fix: OverflowError from the guard's Int32 subtraction
  ensure
    s.try &.destroy
  end
end
