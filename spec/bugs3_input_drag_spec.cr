require "./spec_helper"

include Crysterm

# Regression coverage for the "BUGS3" batch of fixes.
#
# 1. `window_focus.cr` scroll-into-view uses the *scrollable element's own*
#    viewport height, not the window's, so focusing an off-screen child of a
#    scrollable container that is NOT anchored at the window top scrolls the
#    child into the container's own viewport (rather than over/under-scrolling
#    by the container's own top offset).
#
# 2. `window_mouse.cr` does not inflate `#click_count` for a press that is
#    swallowed by a two-click drag start (`#reset_click_count`), so a later
#    normal click reads a fresh count.

private def bugs3_screen(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h)
end

# Build a scrollable container nested inside a *bordered* outer box placed
# below the window top. The nesting (outer `ibottom > 0`) is what makes the
# pre-fix, window-based viewport formula
#   `window.aheight - el.atop - el.itop - el.abottom - el.ibottom`
# disagree with the element-based one
#   `el.aheight - el.itop - el.ibottom`
# by the outer box's `ibottom`: for a direct child of the window the two are
# algebraically identical, so the bug only surfaces one level down. The
# container itself is borderless so a child's `rtop` maps cleanly to a content
# row (no border offset to muddy the `[base, base + visible)` assertion).
private def scroll_fixture(s)
  outer = Widget::Box.new(
    parent: s, top: 5, left: 0, width: 24, height: 12,
    style: Style.new(border: true))
  container = Widget::ScrollableBox.new(
    parent: outer, top: 0, left: 0, width: 18, height: 6)
  children = [] of Widget::Box
  12.times do |i|
    children << Widget::Box.new(
      parent: container, top: i, left: 0, width: 14, height: 1,
      keys: true, content: "child #{i}")
  end
  {container, children}
end

describe "BUGS3 scroll-into-view uses the container's own viewport" do
  it "computes the viewport from the element, not the window (they differ when nested)" do
    s = bugs3_screen
    container, _ = scroll_fixture s
    s.render

    element_based = (container.aheight || 0) - container.itop - container.ibottom
    window_based = s.aheight - container.atop - container.itop -
                   container.abottom - container.ibottom
    # If these were equal the scenario wouldn't exercise the fix at all.
    element_based.should_not eq window_based
    element_based.should be > window_based
  end

  it "scrolls an off-screen child into a below-top scrollable container's viewport" do
    s = bugs3_screen
    container, children = scroll_fixture s
    s.render

    visible = (container.aheight || 0) - container.itop - container.ibottom
    visible.should be > 0

    # Focus a child that is off the bottom of the container's viewport.
    target = children[10]
    target.rtop.should be >= visible # genuinely off-screen before focus

    s.focus target
    s.render

    base = container.child_base
    # The focused child's content row must now sit inside the visible window
    # `[base, base + visible)`. With the pre-fix (smaller) viewport the
    # container over-scrolled and this fell outside the window.
    (target.rtop >= base).should be_true
    (target.rtop < base + visible).should be_true
  end

  it "does not scroll when the focused child already fits the viewport" do
    s = bugs3_screen
    container, children = scroll_fixture s
    s.render
    container.child_base.should eq 0

    # First child is already visible: focusing it must not scroll the container.
    s.focus children[0]
    s.render
    container.child_base.should eq 0
  end
end

describe "BUGS3 two-click drag does not inflate click_count" do
  it "starts fresh on a later normal click after a two-click drag press" do
    s = bugs3_screen
    s.drag_two_click = true

    # A draggable widget the two-click drag will pick up.
    box = Widget::Box.new(
      parent: s, top: 2, left: 2, width: 10, height: 3,
      draggable: true, style: Style.new(border: true))

    # A separate normal, clickable widget elsewhere.
    other = Widget::Box.new(
      parent: s, top: 10, left: 2, width: 10, height: 3,
      style: Style.new(border: true))
    other.clickable = true

    s._render

    # Press on the draggable widget: this lifts it into a two-click drag and
    # the press is swallowed (never becomes a Click). It must NOT feed the
    # running click-count.
    s.dispatch_mouse(::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left,
      box.aleft, box.atop, source: :test))
    s.click_count.should eq 0

    # Drop it somewhere with the next press (ends the discrete drag).
    s.dispatch_mouse(::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left,
      other.aleft + 2, other.atop + 1, source: :test))

    # A subsequent normal click on `other` at the same spot: because the drag
    # press did not chain into the count, this reads as a single click (1), not
    # an inflated double/triple.
    counts = [] of Int32
    other.on(Crysterm::Event::Click) { counts << s.click_count }
    s.dispatch_mouse(::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left,
      other.aleft + 2, other.atop + 1, source: :test))

    counts.last.should eq 1
  end
end
