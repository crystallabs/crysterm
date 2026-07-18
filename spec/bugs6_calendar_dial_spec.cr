require "./spec_helper"

include Crysterm

# Regression specs for BUGS6 §1 "Calendar, Dial & Lines".
#
#  BUG 1 (src/widget/dial.cr): the Dial constructor assigned `@minimum`/`@maximum`
#     directly then `@value = (value || @minimum).clamp(@minimum, @maximum)`,
#     bypassing `set_range`'s `max = min if max < min` guard. `Dial.new(minimum:
#     50, maximum: 10)` stored an inverted range, so `50.clamp(50, 10) == 10` and
#     every step re-clamped to 10 — the dial could never move. Fixed by
#     normalizing `@maximum = Math.max(@minimum, @maximum)` before clamping.
#
#  BUG 2 (src/widget/slider.cr): identical unguarded inverted-range pattern in the
#     Slider constructor; same fix.
#
#  BUG 3 (src/widget/calendar.cr): `default_today` is deliberately wrapped so
#     construction never raises where `Time.local` is unavailable, but the
#     render/setter/constructor paths called `Time.local(y, m, d)` unguarded,
#     defeating that fallback. All such calls now route through a guarded
#     `local_date` helper, so construction and the key/setter paths can't raise.
#
#  BUG 4 (src/widget/dial.cr): the pointer glyph and the value text collided when
#     the inner height was <= 2 (both landed on the same row and the value,
#     drawn last, hid the pointer). Fixed by reserving the bottom row for the
#     value and centering the pointer in the rows above it.
#
#  BUG 5 (src/widget/calendar.cr `#day_at`): `c //= 3` mapped a separator column
#     onto the day cell to its left, and trailing columns past the grid onto the
#     last day, so a click in blank/separator area could select an adjacent day.
#     Fixed by rejecting separator columns (`rel % 3 == 2`).

private def bugs6cd_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS6 Dial inverted range (bug 1)" do
  it "normalizes an inverted minimum/maximum and keeps stepping working" do
    s = bugs6cd_screen
    dial = Crysterm::Widget::Dial.new parent: s, minimum: 50, maximum: 10

    # Bounds are ordered (never inverted); matches the SpinBox fix.
    (dial.minimum <= dial.maximum).should be_true
    dial.minimum.should eq 50
    dial.maximum.should eq 50

    # Value clamps into the (collapsed) range instead of getting stuck at the
    # bogus lower `maximum` (10, which was below `minimum`) as it did before.
    dial.value.should eq 50

    # Widen the range so stepping has room, then verify it moves.
    dial.maximum = 60
    before = dial.value
    dial.step_up
    dial.value.should eq before + dial.single_step
    dial.step_down
    dial.value.should eq before
  end

  it "keeps a normal (already-ordered) range untouched" do
    s = bugs6cd_screen
    dial = Crysterm::Widget::Dial.new parent: s, minimum: 0, maximum: 100, value: 40
    dial.minimum.should eq 0
    dial.maximum.should eq 100
    dial.value.should eq 40
  end
end

describe "BUGS6 Slider inverted range (bug 2)" do
  it "normalizes an inverted minimum/maximum and keeps stepping working" do
    s = bugs6cd_screen
    sl = Crysterm::Widget::Slider.new parent: s, minimum: 50, maximum: 10

    (sl.minimum <= sl.maximum).should be_true
    sl.minimum.should eq 50
    sl.maximum.should eq 50
    sl.value.should eq 50

    sl.maximum = 60
    before = sl.value
    sl.step_up
    sl.value.should eq before + sl.single_step
    sl.step_down
    sl.value.should eq before
  end
end

# Row index (within [y0, y1)) of the first row containing a `POINTERS` glyph,
# or nil. Rows/cols are read straight off the rendered window.
private def bugs6cd_pointer_row(s, y0, y1, x0, x1) : Int32?
  (y0...y1).find do |y|
    (x0...x1).any? { |x| Crysterm::Widget::Dial::POINTERS.includes?(s.lines[y][x].char) }
  end
end

private def bugs6cd_row_text(s, y, x0, x1) : String
  String.build { |io| (x0...x1).each { |x| io << s.lines[y][x].char } }
end

describe "BUGS6 Dial pointer/value collision on a short dial (bug 4)" do
  it "keeps the compass pointer visible when inner height is 2 (value on its own row)" do
    s = bugs6cd_screen
    # No border/padding: interior spans the whole 9x2 widget. Value shown.
    dial = Crysterm::Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 2,
      minimum: 0, maximum: 100, value: 0, text_visible: true
    s._render

    x0 = dial.aleft; x1 = dial.aleft + dial.awidth
    y0 = dial.atop; y1 = dial.atop + dial.aheight

    # The pointer must survive on its own row (was overwritten by the value on a
    # 2-row dial before the fix, so no pointer glyph appeared at all).
    prow = bugs6cd_pointer_row(s, y0, y1, x0, x1)
    prow.should_not be_nil

    # The value digits live on a different row, clear of the pointer.
    value_row = (y0...y1).find { |y| bugs6cd_row_text(s, y, x0, x1).includes?("0") }
    value_row.should_not be_nil
    value_row.should_not eq prow
  end

  it "still separates pointer and value on a tall dial" do
    s = bugs6cd_screen
    dial = Crysterm::Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 4,
      minimum: 0, maximum: 100, value: 0, text_visible: true
    s._render

    x0 = dial.aleft; x1 = dial.aleft + dial.awidth
    y0 = dial.atop; y1 = dial.atop + dial.aheight

    prow = bugs6cd_pointer_row(s, y0, y1, x0, x1)
    prow.should_not be_nil
    value_row = (y0...y1).find { |y| bugs6cd_row_text(s, y, x0, x1).includes?("0") }
    value_row.should_not be_nil
    value_row.should_not eq prow
  end
end

describe "BUGS6 Calendar guarded date construction (bug 3)" do
  it "constructs and drives the key/setter paths without raising" do
    s = bugs6cd_screen
    # Plain construction reaches build_content -> local_date; must not raise.
    cal = Crysterm::Widget::Calendar.new parent: s, date: Time.local(2024, 1, 15)
    s._render

    # Home/End and month stepping all build dates through local_date now.
    cal.on_keypress Crysterm::Event::KeyPress.new(' ', Tput::Key::Home)
    cal.date.day.should eq 1
    cal.on_keypress Crysterm::Event::KeyPress.new(' ', Tput::Key::End)
    cal.date.day.should eq 31 # January
    cal.on_keypress Crysterm::Event::KeyPress.new(' ', Tput::Key::PageDown)
    cal.date.month.should eq 2
  end
end

describe "BUGS6 Calendar#day_at separator hit-testing (bug 5)" do
  it "does not select the adjacent day when a separator column is clicked" do
    # Jan 2024 starts on a Monday; Sunday-first, so the second body row holds
    # days 7..13 in columns 0..6. Day cell c occupies content columns c*3 and
    # c*3+1; the separator sits at c*3+2.
    s = bugs6cd_screen
    cal = Crysterm::Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
      date: Time.local(2024, 1, 15)
    cal.grid_visible = true
    s._render

    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop
    grid_top = 2               # nav bar (1) + weekday header (1)
    body_y = ay + grid_top + 1 # second body row (grid_row 1) -> days 7..13

    # Sanity: clicking the day cell for column 2 selects day 9.
    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + 2 * 3, body_y)
    cal.date.day.should eq 9

    # Now the separator column just right of that cell (col 2*3 + 2) must NOT
    # hit-test onto day 9 (or any day): selection stays put.
    cal.selected_date = Time.local(2024, 1, 15)
    cal.date.day.should eq 15
    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + 2 * 3 + 2, body_y)
    cal.date.day.should eq 15 # unchanged: separator selects nothing
  end
end
