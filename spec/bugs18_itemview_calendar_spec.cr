require "./spec_helper"

include Crysterm

# Regression specs for BUGS18 §item-view / calendar (round 3).
#
#  B18-46 (src/mixin/item_view.cr `#remove_item`/`#insert_item`): the mutators
#     realigned `@selected_indices` after an insert/remove but never touched
#     `@nonselectable` (the divider-row set from `#non_selectable_rows=`), so a
#     marker kept pointing at a stale row index once a row before it was
#     inserted/removed — the real divider became selectable/activatable while
#     an ordinary item at the stale index went dead. Fixed by extracting a
#     shared `#shift_index_set` helper and applying it to both sets in both
#     mutators.
#
#  B18-47 (src/widget/calendar.cr `#minimum_date=`/`#maximum_date=`): each
#     single-bound setter fed `#set_date_range`, which SWAPS an inverted pair
#     rather than collapsing — so assigning a minimum above the current
#     maximum kept the OLD maximum as the new minimum and installed the
#     caller's minimum as the maximum (silently inverting caller intent).
#     Fixed to carry the other bound along (`Math.max`/`Math.min`), matching
#     `Mixin::RangedValue#minimum=`/`#maximum=` and Qt.
#
#  B18-49 (src/widget/calendar.cr `#handle_grid_mouse`/`#activate_day`): a
#     display-only calendar (`SelectionMode::NoSelection`) suppressed
#     `Event::DateActivated` on the keyboard path (Enter) but not on a mouse
#     click — `#activate_day` unconditionally emitted the event. Fixed by
#     gating the click dispatch on `!selection_mode.no_selection?`, matching
#     the keyboard path and Qt's `QCalendarWidget`.

private def b18ic_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# ── B18-46 ──────────────────────────────────────────────────────────────────

describe "ItemView non_selectable_rows realignment (B18-46)" do
  it "slides a divider marker down when a row before it is removed" do
    s = b18ic_screen
    list = Crysterm::Widget::List.new parent: s, items: ["Open", "----", "Quit"]
    list.non_selectable_rows = [1]

    list.remove_item 0
    # Rows are now ["----", "Quit"]; the marker must follow the divider to its
    # new row 0, not stay stuck at the stale row 1 (now "Quit").
    list.non_selectable_rows.to_a.should eq [0]

    # The real divider is inert…
    list.current_index = 0
    list.item_selected?(list.item_boxes[0]).should be_false
    # …and the ordinary row is reachable/selectable at its new index.
    list.current_index = 1
    list.current_text.should eq "Quit"
  end

  it "slides a divider marker up when a row is inserted before it" do
    s = b18ic_screen
    list = Crysterm::Widget::List.new parent: s, items: ["----", "Quit"]
    list.non_selectable_rows = [0]

    list.insert_item 0, "Open"
    # Rows are now ["Open", "----", "Quit"]; the marker must follow the
    # divider to row 1, not stay at the stale row 0 (now "Open").
    list.non_selectable_rows.to_a.should eq [1]
    list.current_index = 0
    list.current_text.should eq "Open"
  end

  it "drops a divider marker that sits exactly on the removed row" do
    s = b18ic_screen
    list = Crysterm::Widget::List.new parent: s, items: ["a", "----", "c"]
    list.non_selectable_rows = [1]

    list.remove_item 1
    list.non_selectable_rows.empty?.should be_true
  end

  it "keeps @selected_indices and @nonselectable in lock-step across a mixed sequence" do
    s = b18ic_screen
    list = Crysterm::Widget::List.new parent: s, selection_mode: :multi_selection,
      items: ["a", "b", "----", "d", "e"]
    list.non_selectable_rows = [2]
    list.add_to_selection 3 # "d"

    list.insert_item 0, "z" # shifts everything down by one
    list.non_selectable_rows.to_a.should eq [3]
    list.selected_indices.to_a.should eq [4]

    list.remove_item 0 # removes "z", undoing the shift above
    list.non_selectable_rows.to_a.should eq [2]
    list.selected_indices.to_a.should eq [3]
  end
end

# ── B18-47 ──────────────────────────────────────────────────────────────────

describe "Calendar#minimum_date=/#maximum_date= carry semantics (B18-47)" do
  it "carries the maximum up when a new minimum crosses it, instead of swapping" do
    s = b18ic_screen
    cal = Crysterm::Widget::Calendar.new parent: s

    cal.maximum_date = Time.utc(2020, 1, 1)
    cal.minimum_date = Time.utc(2030, 1, 1)

    # The range collapses to the assigned value, matching RangedValue/Qt — it
    # does NOT swap to [2020-01-01, 2030-01-01], which would silently make the
    # caller's minimum the maximum and leave 2020-2029 selectable.
    cal.minimum_date.should eq Time.utc(2030, 1, 1)
    cal.maximum_date.should eq Time.utc(2030, 1, 1)
  end

  it "carries the minimum down when a new maximum crosses it, instead of swapping" do
    s = b18ic_screen
    cal = Crysterm::Widget::Calendar.new parent: s

    cal.minimum_date = Time.utc(2030, 1, 1)
    cal.maximum_date = Time.utc(2020, 1, 1)

    cal.minimum_date.should eq Time.utc(2020, 1, 1)
    cal.maximum_date.should eq Time.utc(2020, 1, 1)
  end

  it "leaves a non-crossing assignment ordered normally" do
    s = b18ic_screen
    cal = Crysterm::Widget::Calendar.new parent: s

    cal.minimum_date = Time.utc(2020, 1, 1)
    cal.maximum_date = Time.utc(2030, 1, 1)

    cal.minimum_date.should eq Time.utc(2020, 1, 1)
    cal.maximum_date.should eq Time.utc(2030, 1, 1)
  end
end

# ── B18-49 ──────────────────────────────────────────────────────────────────

describe "Calendar display-only (NoSelection) click suppression (B18-49)" do
  it "does not emit DateActivated on a click when selection_mode is NoSelection" do
    s = b18ic_screen
    cal = Crysterm::Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
      date: Time.local(2024, 1, 15)
    cal.selection_mode = :no_selection
    s.repaint

    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop
    grid_top = 2               # nav bar (1) + weekday header (1)
    body_y = ay + grid_top + 1 # second body row (grid_row 1) -> days 7..13

    activated = [] of Time
    cal.on(Crysterm::Event::DateActivated) { |e| activated << e.date }

    # Same cell the sibling BUGS6 spec uses to hit day 9 (column 2, body row 1).
    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + 2 * 3, body_y)

    activated.empty?.should be_true
    cal.date.day.should eq 15 # unchanged: NoSelection also never moves @date
  end

  it "still emits DateActivated on a click in the default SingleSelection mode" do
    s = b18ic_screen
    cal = Crysterm::Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
      date: Time.local(2024, 1, 15)
    s.repaint

    ax = cal.aleft + cal.ileft
    ay = cal.atop + cal.itop
    grid_top = 2
    body_y = ay + grid_top + 1

    activated = [] of Time
    cal.on(Crysterm::Event::DateActivated) { |e| activated << e.date }

    s.dispatch_mouse Tput::Mouse::Event.new(
      Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, ax + 2 * 3, body_y)

    activated.size.should eq 1
    activated.first.day.should eq 9
    cal.date.day.should eq 9
  end
end
