require "./spec_helper"

include Crysterm

# Regression: wheeling over an open completer drop-down used to let the
# hover-select highlight fight the wheel. Once the pointer drifted across a row
# boundary mid-scroll, the per-row `MouseEnter` re-pinned the selection to the
# entry under the cursor, so the list could never scroll past the first page —
# the selection "jumped back under the cursor".
#
# Fix (Option A): the wheel scrolls the *view* (`#child_base`) and re-selects the
# entry that lands under the cursor. Hover-select and the wheel now share one
# rule ("selected == entry under the cursor"), so they agree instead of fighting.

private def cws_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

private def cws_build(s)
  box = Crysterm::Widget::LineEdit.new parent: s, top: 5, left: 10, width: 18, height: 1
  completer = Crysterm::Completer.new %w[Crystal Ruby Rust Python Perl PHP Go Groovy Java JavaScript Kotlin Lua]
  completer.attach box
  box.focus
  s._render
  # Down opens the popup on the whole model (combo-box style).
  box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
  s._render
  {box, completer, completer.@popup.not_nil!}
end

private def cws_move(s, x, y)
  s.dispatch_mouse(Tput::Mouse::Event.new(Tput::Mouse::Action::Move, Tput::Mouse::Button::None, x, y, source: :test))
  # Re-render so item hit rectangles (`lpos`) reflect the current scroll, exactly
  # as the running app repaints between input events — mouse hit-testing reads
  # `lpos`, so a stale frame would mis-map which entry is under the pointer.
  s._render
end

private def cws_wheel(s, dir, x, y)
  act = dir > 0 ? Tput::Mouse::Action::WheelDown : Tput::Mouse::Action::WheelUp
  s.dispatch_mouse(Tput::Mouse::Event.new(act, Tput::Mouse::Button::None, x, y, source: :test))
  s._render
end

describe "Completer drop-down wheel scrolling" do
  it "scrolls past the visible page under a stationary cursor and reaches the last entry" do
    s = cws_screen
    _box, completer, pop = cws_build s
    completer.open?.should be_true
    pop.@items.size.should be > pop.visible_content_rows # must actually overflow

    x = pop.aleft + 2
    base = pop.atop + pop.itop
    12.times { cws_wheel s, 1, x, base + 2 }        # wheel down, cursor held on row 2
    pop.@child_base.should be > 0                   # the view scrolled past page one
    pop.current_index.should eq pop.@items.size - 1 # every entry is reachable by the wheel
    completer.open?.should be_true
  end

  it "keeps scrolling past the first page even when the cursor drifts (the jump-back bug)" do
    # The bug: a drifting pointer re-pinned the selection to the cursor's row, so
    # `child_base` never advanced — the list was stuck on page one no matter how
    # much you wheeled. Here the view must still scroll, and the selection tracks
    # the entry under the (drifting) cursor rather than snapping back.
    s = cws_screen
    _box, _completer, pop = cws_build s
    x = pop.aleft + 2
    base = pop.atop + pop.itop
    12.times do |i|
      row = 2 + (i % 2) # drift 2,3,2,3... like a real hand
      cws_move s, x, base + row
      cws_wheel s, 1, x, base + row
    end
    pop.@child_base.should be > 0                                   # NOT stuck on page one
    pop.current_index.should eq pop.@child_base + pop.@child_offset # selection == entry under cursor
  end

  it "tracks the entry under the pointer as the mouse moves (hover-select)" do
    # Moving the mouse over the open list must change which entry is highlighted,
    # both before and after the list has been scrolled.
    s = cws_screen
    _box, _completer, pop = cws_build s
    x = pop.aleft + 2
    base = pop.atop + pop.itop

    [0, 1, 2, 3, 2, 1].each do |row|
      cws_move s, x, base + row
      pop.current_index.should eq row # unscrolled: selection == the row under the pointer
    end

    # Scroll to the very bottom, then hover each visible row: the highlight must
    # follow the pointer to a *distinct* entry per row (child_base + visual row),
    # not sit stuck on the last one. Regression: once scrolled, hovering the
    # visible rows did nothing because the hook mis-treated the item's absolute
    # index as a viewport row and clamped it to the last visible slot.
    15.times { cws_wheel s, 1, x, base + 2 }
    cb = pop.@child_base
    cb.should be > 0
    vis = pop.visible_content_rows
    (0...vis).each do |row|
      cws_move s, x, base + row
      pop.current_index.should eq cb + row
    end
  end

  it "wheels back up to the first entry" do
    s = cws_screen
    _box, completer, pop = cws_build s
    x = pop.aleft + 2
    base = pop.atop + pop.itop
    20.times { cws_wheel s, 1, x, base + 2 } # go to the bottom
    pop.current_index.should eq pop.@items.size - 1
    20.times { cws_wheel s, -1, x, base + 2 } # and all the way back
    pop.current_index.should eq 0
    pop.@child_base.should eq 0
    completer.open?.should be_true # scrolling never dismisses the popup
  end
end
