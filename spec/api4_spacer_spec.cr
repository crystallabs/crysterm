require "./spec_helper"

include Crysterm

# Specs for API4 A4-30 — `Layout::Box#add_spacing` / `#add_stretch` and the
# `Widget::Spacer` widget behind them (Qt's `QBoxLayout::addSpacing`/
# `addStretch` + `QSpacerItem`):
#
# * a stretch spacer between two fixed children pins them to the two edges;
# * `add_spacing(5)` produces an exact 5-cell gap;
# * two stretch spacers with factors 1 and 2 divide the leftover 1:2 through
#   the box's normal grow distribution;
# * Tab traversal skips spacers (never registered as keyable, explicit
#   `FocusPolicy::None`);
# * `Window#widget_at` over the gap reports the container, not the spacer
#   (`Spacer#wants_mouse?` is hard-wired false).

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "API4 A4-30 Layout::Box#add_stretch / #add_spacing" do
  it "add_stretch between two fixed buttons pins them to the edges" do
    screen = headless_screen
    hbox = Layout::HBox.new
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 3,
      layout: hbox
    b1 = Widget::Button.new parent: box, width: 5, height: 1, content: "B1"
    sp = hbox.add_stretch
    b2 = Widget::Button.new parent: box, width: 5, height: 1, content: "B2"
    screen.repaint

    b1.aleft.should eq 0
    # The stretch spacer soaks up the whole 20-cell leftover...
    sp.awidth.should eq 20
    # ...pushing the second button flush against the right edge.
    b2.aleft.should eq 25
  end

  it "add_spacing(5) leaves an exact 5-cell gap between two buttons" do
    screen = headless_screen
    hbox = Layout::HBox.new
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 3,
      layout: hbox
    b1 = Widget::Button.new parent: box, width: 5, height: 1, content: "B1"
    sp = hbox.add_spacing 5
    b2 = Widget::Button.new parent: box, width: 5, height: 1, content: "B2"
    screen.repaint

    b1.aleft.should eq 0
    sp.awidth.should eq 5
    # 0..5 button, 5..10 gap, button starts at 10 — an exact 5-cell gap.
    b2.aleft.should eq 10
  end

  it "stretch factors 1 and 2 divide the leftover 1:2" do
    screen = headless_screen
    hbox = Layout::HBox.new
    # 33 wide - 3 x 5-wide buttons = 18 leftover, divided 1:2 -> 6 and 12.
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 33, height: 3,
      layout: hbox
    b1 = Widget::Button.new parent: box, width: 5, height: 1, content: "B1"
    s1 = hbox.add_stretch 1
    b2 = Widget::Button.new parent: box, width: 5, height: 1, content: "B2"
    s2 = hbox.add_stretch 2
    b3 = Widget::Button.new parent: box, width: 5, height: 1, content: "B3"
    screen.repaint

    s1.awidth.should eq 6
    s2.awidth.should eq 12
    b1.aleft.should eq 0
    b2.aleft.should eq 11 # 5 + 6
    b3.aleft.should eq 28 # 11 + 5 + 12, flush against the right edge
  end

  it "works on the vertical axis too (VBox add_spacing gaps rows)" do
    screen = headless_screen
    vbox = Layout::VBox.new
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 10, height: 12,
      layout: vbox
    b1 = Widget::Button.new parent: box, width: 5, height: 1, content: "B1"
    vbox.add_spacing 5
    b2 = Widget::Button.new parent: box, width: 5, height: 1, content: "B2"
    screen.repaint

    b1.atop.should eq 0
    # Row 0 button, rows 1..6 gap, second button on row 6.
    b2.atop.should eq 6
  end

  it "focus traversal from button1 reaches button2, skipping the spacer" do
    screen = headless_screen
    hbox = Layout::HBox.new
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 3,
      layout: hbox
    b1 = Widget::Button.new parent: box, width: 5, height: 1, content: "B1"
    sp = hbox.add_stretch
    b2 = Widget::Button.new parent: box, width: 5, height: 1, content: "B2"
    screen.repaint

    # The spacer's focus policy is pinned to None: not a Tab target, and never
    # registered as keyable in the first place.
    sp.accepts_tab_focus?.should be_false
    sp.focus_policy.none?.should be_true

    b1.focus
    screen.focused.should eq b1
    screen.focus_next
    screen.focused.should eq b2
    sp.focused?.should be_false
    # And back around: Shift+Tab from b2 lands on b1, again skipping the spacer.
    screen.focus_previous
    screen.focused.should eq b1
  end

  it "widget_at over the gap returns the container, not the spacer" do
    screen = headless_screen
    hbox = Layout::HBox.new
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 3,
      layout: hbox
    box.clickable = true
    Widget::Button.new parent: box, width: 5, height: 1, content: "B1"
    sp = hbox.add_stretch
    Widget::Button.new parent: box, width: 5, height: 1, content: "B2"
    screen.repaint

    # (15, 1) is inside the stretch gap (cells 5..25 of row 0..3): the spacer
    # occupies it but wants no mouse, so the hit falls through to the container.
    sp.wants_mouse?.should be_false
    screen.widget_at(15, 1).should eq box
  end

  it "raises when the layout is not installed on a container" do
    expect_raises(ArgumentError, /add_stretch/) { Layout::HBox.new.add_stretch }
    expect_raises(ArgumentError, /add_spacing/) { Layout::HBox.new.add_spacing 3 }
  end
end
