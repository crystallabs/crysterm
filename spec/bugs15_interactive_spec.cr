require "./spec_helper"

include Crysterm

# BUGS15 #9 / #43 / #44 / #12 — interactive-widget geometry fixes.
#
#  #9  Calendar mapped mouse clicks through layout coords (aleft/atop), so a
#      click inside a scrolled container selected the wrong day. Fixed to map
#      through the painted position (@lpos), mirroring Mixin::CheckMarker.
#  #43 Slider/ScrollBar/Dial render math subtracted `value - minimum` in Int32,
#      overflowing (OverflowError, render fiber crash) for a full-Int32-span
#      range. Fixed by widening the subtraction to Int64.
#  #44 Slider painted its track/handle in the border-only interior but mapped
#      clicks with padding-inclusive insets. Fixed to render into the content
#      region (border + padding) so both box models agree.
#  #12 ListTable horizontal scroll floor-snapped the reachable column, leaving
#      the table's right edge permanently unreachable. Fixed with a ceil bump.

private def i15_row(s, y, x0, x1) : String
  String.build { |io| (x0...x1).each { |x| io << s.lines[y][x].char } }
end

private def i15_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 30,
    default_quit_keys: false)
end

# ── #9 Calendar painted-coord hit-test ──────────────────────────────────────

describe "BUGS15 9: Calendar hit-tests through the painted position, not layout coords" do
  it "selects the day under the painted cell when inside a scrolled container" do
    s = i15_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 20, scrollable: true
    # Tall spacer so the container has room to scroll past its viewport.
    Widget::Box.new parent: outer, top: 25, left: 0, width: 1, height: 10
    # Jan 2024 starts on a Monday (Sunday-first): the second body row holds
    # days 7..13 in columns 0..6, so column index 2 -> day 9.
    cal = Widget::Calendar.new parent: outer, top: 3, left: 0, width: 24, height: 14,
      date: Time.local(2024, 1, 15)
    cal.grid_visible = true
    s._render

    # Scroll the container down 3 rows (into the child_base, which drives the
    # paint shift): the calendar paints 3 rows higher than its layout `atop`.
    # `aleft`/`atop`-based mapping would resolve 3 rows off.
    outer.scroll_to 3, always: true
    s._render
    lp = cal.lpos.not_nil!
    lp.yi.should eq cal.atop - outer.child_base # painted position is shifted up

    ax = lp.xi + cal.ileft
    ay = lp.yi + cal.itop
    grid_top = 2               # nav bar (1) + weekday header (1)
    body_y = ay + grid_top + 1 # second body row (grid_row 1) -> days 7..13

    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + 2 * 3, body_y)
    # Painted-coord mapping resolves the clicked cell to day 9. The old
    # layout-coord mapping resolved a cell 3 rows too high (nav bar / earlier
    # week), leaving the selection unchanged at 15.
    cal.date.day.should eq 9
  end
end

# ── #43 Int64-widened render math for full-span ranges ──────────────────────

describe "BUGS15 43: Slider/ScrollBar/Dial render math survives a full Int32-span range" do
  it "renders a Slider with minimum Int32::MIN and value 0 without overflowing" do
    s = i15_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 40, height: 3,
      minimum: Int32::MIN, maximum: Int32::MAX, value: 0
    # `handle_offset` did `(@value - @minimum)` in Int32 -> OverflowError.
    s._render
    sl.value.should eq 0
  end

  it "renders a Slider's ticks across a full-span range without overflowing" do
    s = i15_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 40, height: 3,
      minimum: Int32::MIN, maximum: Int32::MAX, value: 0,
      tick_position: Widget::Slider::TickPosition::Both
    s._render # `each_tick_cell`'s `(tv - @minimum)` also widened
    sl.value.should eq 0
  end

  it "renders a standalone ScrollBar with minimum Int32::MIN without overflowing" do
    s = i15_screen
    sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 12,
      minimum: Int32::MIN, maximum: Int32::MAX, value: 0
    # `thumb_offset` did `(slider_position - @minimum)` in Int32 -> OverflowError.
    s._render
    sb.value.should eq 0
  end

  it "renders a Dial with minimum Int32::MIN without overflowing" do
    s = i15_screen
    dial = Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 3,
      minimum: Int32::MIN, maximum: Int32::MAX, value: 0, text_visible: false
    # `pointer` did `(@value - @minimum)` in Int32 -> OverflowError.
    s._render
    dial.value.should eq 0
  end
end

# ── #44 Slider paints into the padded content region ────────────────────────

describe "BUGS15 44: Slider paints its track in the content region (padding respected)" do
  it "does not paint the track over the horizontal padding cells" do
    s = i15_screen
    # padding: 0 2 (top/bottom 0, left/right 2) — Padding.new(left, top, right, bottom).
    # Set via the constructor style so it survives the per-frame style resolution.
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 24, height: 1,
      minimum: 0, maximum: 100, value: 50,
      track_char: '-', handle_char: '#',
      style: Crysterm::Style.new(padding: Crysterm::Padding.new(2, 0, 2, 0))
    s._render

    lp = sl.lpos.not_nil!
    row = lp.yi
    # The two left and two right padding cells must NOT carry the track/handle:
    # the old border-only render painted the full 24 cells, overlapping padding.
    sl.ileft.should eq 2
    {lp.xi, lp.xi + 1, lp.xi + 22, lp.xi + 23}.each do |x|
      c = s.lines[row][x].char
      c.should_not eq '-'
      c.should_not eq '#'
    end
    # The content region (cols xi+2 .. xi+21) carries the track, and the handle
    # falls inside it — so the drawn handle and the click-mapped value share the
    # same origin/span.
    s.lines[row][lp.xi + 2].char.should eq '-'
    handle_x = (lp.xi + 2..lp.xi + 21).find { |x| s.lines[row][x].char == '#' }
    handle_x.should_not be_nil
  end
end

# ── #12 ListTable horizontal scroll reaches the right edge ───────────────────

describe "BUGS15 12: ListTable horizontal scroll can reach the table's right edge" do
  it "scrolls to expose the last column when no column starts exactly at max_left" do
    s = i15_screen
    lt = Widget::ListTable.new parent: s, top: 0, left: 0, width: 16, height: 8,
      rows: [["Name", "City"], ["aaaaaaaaaa", "bbbbbbbbbb"]]
    s._render

    # maxes = [12, 12]; row_width 26; offsets [0, 13]; viewport 16; max_left 10.
    lt.column_start_offsets.should eq [0, 13]
    lt.overflows_x?.should be_true
    lt.child_base_x.should eq 0

    # Old floor-snap clamped the reachable column to 0 (offset 0 <= 10), so any
    # scroll no-op'd and the "City" column tail was unreachable. The ceil bump
    # lets the scroll snap to column 1 (offset 13).
    lt.scroll_by_x 1
    s._render
    lt.child_base_x.should eq 13
    # The right-edge column (data row 1) is now on screen — previously dead.
    i15_row(s, 1, 0, 12).should contain "bbbbbbbbbb"

    # And it can scroll back to the origin.
    lt.scroll_by_x -1
    s._render
    lt.child_base_x.should eq 0
  end
end
