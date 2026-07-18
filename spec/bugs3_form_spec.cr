require "./spec_helper"

include Crysterm

# Specs for the BUGS3 form/spinbox/date-edit fixes:
#
#  1. `Form#field_value` now collects `SpinBox`/`DoubleSpinBox`/`ComboBox`/
#     `DateEdit`/`TimeEdit`/`DateTimeEdit` values on `#submit` (previously
#     dropped, since only text/list/check widgets were matched).
#  2. `Form#reset` now resets those same widgets (spin boxes to their minimum,
#     combo boxes to the first option, date/time editors to "now"). A public
#     `ComboBox#reset` was added.
#  3. `SpinBox`/`DoubleSpinBox` constructors normalize an inverted
#     `minimum > maximum` range so the value isn't left permanently stuck.
#  4. `DateEdit#section_at` maps the separator columns consistently with
#     `DateTimeEdit#section_at` (col 4 -> year, col 7 -> month).

private def form_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Dispatch a left-button press at absolute column *col* of a widget's top row.
private def click_col(s, w, col)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left,
    w.aleft + col, w.atop)
end

describe "BUGS3 Form field collection (fix #1)" do
  it "#submit collects SpinBox, ComboBox and DateEdit values" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)

    sb = Crysterm::Widget::SpinBox.new(
      parent: form, name: "count", top: 0, left: 0, width: 10, height: 1,
      minimum: 0, maximum: 100, value: 42)
    cb = Crysterm::Widget::ComboBox.new(
      parent: form, name: "color", top: 1, left: 0, width: 12, height: 1,
      options: ["red", "green", "blue"], current_index: 1)
    de = Crysterm::Widget::DateEdit.new(
      parent: form, name: "when", top: 2, left: 0, width: 12, height: 1,
      date: Time.utc(2021, 3, 14))

    s.render

    form.submit
    data = form.submission.not_nil!

    data["count"]?.should eq "42"
    data["color"]?.should eq "green"
    data["when"]?.should eq "2021-03-14"

    # Sanity: the widgets themselves hold those values.
    sb.value.should eq 42
    cb.current_text.should eq "green"
    de.date.should eq Time.utc(2021, 3, 14).at_beginning_of_day
  end

  it "#submit collects a DoubleSpinBox's formatted value" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    Crysterm::Widget::DoubleSpinBox.new(
      parent: form, name: "ratio", top: 0, left: 0, width: 10, height: 1,
      minimum: 0.0, maximum: 10.0, decimals: 2, value: 3.5)

    s.render
    form.submit
    form.submission.not_nil!["ratio"]?.should eq "3.50"
  end
end

describe "BUGS3 Form reset (fix #2)" do
  it "resets SpinBox to its minimum and ComboBox to its first option" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)

    sb = Crysterm::Widget::SpinBox.new(
      parent: form, name: "count", top: 0, left: 0, width: 10, height: 1,
      minimum: 5, maximum: 100, value: 42)
    cb = Crysterm::Widget::ComboBox.new(
      parent: form, name: "color", top: 1, left: 0, width: 12, height: 1,
      options: ["red", "green", "blue"], current_index: 2)

    s.render

    sb.value.should eq 42
    cb.current_text.should eq "blue"

    form.reset

    sb.value.should eq sb.minimum
    sb.value.should eq 5
    cb.current_text.should eq "red"
    cb.current_index.should eq 0
  end

  it "resets a DoubleSpinBox to its minimum" do
    s = form_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    dsb = Crysterm::Widget::DoubleSpinBox.new(
      parent: form, name: "ratio", top: 0, left: 0, width: 10, height: 1,
      minimum: 1.0, maximum: 10.0, value: 7.0)

    s.render
    form.reset
    dsb.value.should eq dsb.minimum
    dsb.value.should eq 1.0
  end
end

describe "BUGS3 SpinBox inverted-range constructor (fix #3)" do
  it "normalizes an inverted minimum/maximum and keeps stepping working" do
    s = form_screen
    sb = Crysterm::Widget::SpinBox.new(
      parent: s, top: 0, left: 0, width: 10, height: 1,
      minimum: 50, maximum: 10)

    # Bounds are ordered (never inverted).
    (sb.minimum <= sb.maximum).should be_true
    sb.minimum.should eq 50
    sb.maximum.should eq 50

    # Value clamps into the (collapsed) range rather than getting stuck.
    sb.value.should eq 50

    # Widen the range so stepping actually has room, then verify it moves.
    sb.maximum = 60
    before = sb.value
    sb.step_up
    sb.value.should_not eq before
    sb.value.should eq before + sb.single_step
    sb.step_down
    sb.value.should eq before
  end
end

describe "BUGS3 DoubleSpinBox inverted-range constructor (fix #3)" do
  it "normalizes an inverted minimum/maximum and keeps stepping working" do
    s = form_screen
    dsb = Crysterm::Widget::DoubleSpinBox.new(
      parent: s, top: 0, left: 0, width: 10, height: 1,
      minimum: 50.0, maximum: 10.0)

    (dsb.minimum <= dsb.maximum).should be_true
    dsb.minimum.should eq 50.0
    dsb.maximum.should eq 50.0
    dsb.value.should eq 50.0

    dsb.maximum = 60.0
    before = dsb.value
    dsb.step_up
    dsb.value.should_not eq before
    dsb.value.should eq before + dsb.single_step
    dsb.step_down
    dsb.value.should eq before
  end
end

describe "BUGS3 DateEdit#section_at consistency (fix #4)" do
  it "maps the first dash (col 4) to the year section, like DateTimeEdit" do
    s = form_screen
    de = Crysterm::Widget::DateEdit.new(
      parent: s, top: 0, left: 0, width: 20, height: 1,
      date: Time.utc(2021, 3, 14), calendar_popup: false)
    s.render

    # Opens on the day section (index 2): the day is highlighted.
    de.content.should eq "2021-03-{reverse}14{/reverse}"

    # Click the first dash (col 4): selects the year section (index 0),
    # matching DateTimeEdit's col-4 -> year mapping.
    click_col s, de, 4
    de.content.should eq "{reverse}2021{/reverse}-03-14"

    # Click the second dash (col 7): selects the month section (index 1).
    click_col s, de, 7
    de.content.should eq "2021-{reverse}03{/reverse}-14"
  end

  it "matches DateTimeEdit's section for the shared columns 4 and 7" do
    s = form_screen
    dte = Crysterm::Widget::DateTimeEdit.new(
      parent: s, top: 0, left: 0, width: 24, height: 1,
      date_time: Time.utc(2021, 3, 14, 9, 8, 7))
    s.render

    # Col 4 (first dash) -> year section highlighted.
    click_col s, dte, 4
    dte.content.should eq "{reverse}2021{/reverse}-03-14 09:08:07"

    # Col 7 (second dash) -> month section highlighted.
    click_col s, dte, 7
    dte.content.should eq "2021-{reverse}03{/reverse}-14 09:08:07"
  end
end
