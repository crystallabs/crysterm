require "./spec_helper"

include Crysterm

# Regression coverage for a batch of BUGS-F1 findings owned by this agent:
#
#  20 (macros.cr)            `alias_previous` created a junk `new_method` instead
#                            of the requested alias, so `Message#log` /
#                            `Window#reset_cursor` never existed.
#  30 (window_mouse.cr)      a disabled `draggable?` widget could still be dragged.
#  36 (lineedit.cr)          a pre-seeded history was unreachable via Up (and Down
#                            walked the wrong way).
#  37 (message.cr)           a stale timeout fiber dismissed a later message early.
#  38 (scrollbar.cr)         a tracked drag froze once the pointer left the 1-col bar.
#  39 (donut.cr)             the caption row was stamped onto the bottom border.
#  49 (button_group.cr)      a raising handler left `@suppress` stuck, killing
#                            exclusivity.
#  52 (widget_label.cr)      the update path ignored padding, shifting the label.

private def f1_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h,
    default_quit_keys: false)
end

private def f1_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

describe "BUGS-F1 finding 20: alias_previous defines the requested alias" do
  it "supports Widget::Message#display block-less overload" do
    s = f1_screen
    m = Crysterm::Widget::Message.new parent: s
    # `-1.seconds` selects the keypress-dismissal path (no timer fiber).
    m.display("saved", -1.seconds)
    m.visible?.should be_true
  end

  it "creates Window#reset_cursor" do
    s = f1_screen
    # Real method now (was a no-op junk `new_method` before the fix); calling it
    # must not raise.
    s.reset_cursor
  end
end

describe "BUGS-F1 finding 30: a disabled draggable widget cannot be dragged" do
  it "does not move on press+motion when disabled" do
    s = f1_screen
    box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4,
      draggable: true
    box.state = Crysterm::WidgetState::Disabled
    s.repaint

    s.dispatch_mouse f1_mouse(::Tput::Mouse::Action::Down, 12, 6)
    s.dispatch_mouse f1_mouse(::Tput::Mouse::Action::Move, 20, 12, ::Tput::Mouse::Button::None)

    s.drag_session.should be_nil
    box.left.should eq 10
    box.top.should eq 5
  end

  it "still drags when enabled (harness sanity)" do
    s = f1_screen
    box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4,
      draggable: true
    s.repaint

    s.dispatch_mouse f1_mouse(::Tput::Mouse::Action::Down, 12, 6)
    s.dispatch_mouse f1_mouse(::Tput::Mouse::Action::Move, 20, 12, ::Tput::Mouse::Button::None)

    box.left.should eq 18
  end
end

describe "BUGS-F1 finding 36: pre-seeded LineEdit history is reachable via Up" do
  it "Up recalls the most recent entry first; Down returns to the draft" do
    s = f1_screen
    le = Widget::LineEdit.new parent: s
    le.history << "one"
    le.history << "two"
    le.history << "three"

    up = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Up
    down = Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Down

    le._listener up
    le.value.should eq "three" # most recent, not stuck on the live line
    le._listener up
    le.value.should eq "two"
    le._listener down
    le.value.should eq "three"
    le._listener down
    le.value.should eq "" # back on the (empty) live-line draft
  end
end

describe "BUGS-F1 finding 37: a stale message timer does not dismiss a later message" do
  it "no-ops end_it from a superseded generation" do
    s = f1_screen
    m = Crysterm::Widget::Message.new parent: s

    calls = [] of Int32
    # Long timers so the spawned fibers never fire during the test.
    m.display("a", 100.seconds) { calls << 1 }
    m.display("b", 100.seconds) { calls << 2 }
    m.visible?.should be_true

    # The first message's timer (generation 1) fires late: it must not dismiss
    # "b" (generation 2), and its callback must not run.
    m.end_it(1) { calls << 99 }
    m.visible?.should be_true
    calls.empty?.should be_true

    # The current generation's dismissal works normally.
    m.end_it(2) { calls << 100 }
    m.visible?.should be_false
    calls.should eq [100]
  end
end

describe "BUGS-F1 finding 38: ScrollBar keeps tracking a drag that leaves the bar" do
  it "delivers off-bar motion to the captured bar (tracking mode)" do
    s = f1_screen
    sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 12,
      minimum: 0, maximum: 100
    s.repaint

    # Press in the middle of the 1-column trough.
    s.dispatch_mouse f1_mouse(::Tput::Mouse::Action::Down, 0, 6)
    mid = sb.value
    mid.should be < 100

    # Drag to the bottom but with the pointer OFF the bar (x = 5). Without the
    # unconditional capture this motion hit-tests to nothing and the thumb
    # freezes at `mid`; with it, the bar receives the motion and reaches the end.
    s.dispatch_mouse f1_mouse(::Tput::Mouse::Action::Move, 5, 11)
    sb.value.should eq 100
  end
end

describe "BUGS-F1 finding 39: Donut caption is not stamped onto the bottom border" do
  it "skips the caption when the interior is 1 row, but draws it when there is room" do
    s = f1_screen

    # Height 3 + border -> a single interior row: the caption row would fall on
    # the bottom border and must be skipped.
    Widget::Graph::Donut.new parent: s, top: 0, left: 0,
      width: 12, height: 3, value: 0, label: "CPU",
      style: Style.new(border: true)

    # Height 5 + border -> 3 interior rows: the caption fits on its own row.
    Widget::Graph::Donut.new parent: s, top: 4, left: 0,
      width: 12, height: 5, value: 0, label: "CPU",
      style: Style.new(border: true)

    s.repaint

    # The centered "CPU" would land at column 4 (xi=1, width 12).
    # Tight donut: bottom border row is 2 — must NOT hold the caption.
    s.lines[2][4].char.should_not eq 'C'
    # Roomy donut: interior caption row is 4+3 = 7 — must hold it.
    s.lines[7][4].char.should eq 'C'
  end
end

describe "BUGS-F1 finding 49: ButtonGroup exclusivity survives a raising handler" do
  it "resets @suppress even when a StateChanged handler raises" do
    s = f1_screen
    a = Widget::CheckBox.new parent: s
    b = Widget::CheckBox.new parent: s

    group = ButtonGroup.new
    group.add_button a
    group.add_button b

    a.check
    a.checked?.should be_true

    # A user handler that raises while the group is unchecking `a` (inside the
    # `suppressed` block triggered by checking `b`).
    a.on(Crysterm::Event::StateChanged) { |e| raise "boom" if e.state.unchecked? }

    expect_raises(Exception, "boom") do
      b.check
    end

    # Post-exception: `a` got unchecked before the raise, `b` is checked.
    a.checked?.should be_false
    b.checked?.should be_true

    # With `@suppress` correctly reset by `ensure`, exclusivity still works:
    # checking `a` unchecks `b`. (Before the fix `@suppress` stayed true and the
    # exclude step was skipped, leaving both checked.)
    a.check
    a.checked?.should be_true
    b.checked?.should be_false
  end
end

describe "BUGS-F1 finding 52: set_label update path honors padding" do
  it "keeps the label position stable across a second set_label" do
    s = f1_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6,
      style: Style.new(border: true, padding: Padding.new(2, 0, 2, 0))

    box.set_label "A"
    first = box.label_widget.not_nil!.left

    box.set_label "B"
    second = box.label_widget.not_nil!.left

    second.should eq first
    # Sanity: padding is actually present (border 1 + padding 2), so the buggy
    # `2 + (-border.left)` path would have differed from this value.
    first.should eq 2 - box.ileft
  end
end
