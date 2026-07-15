require "./spec_helper"

include Crysterm

# Regression specs for the scrolling / scrollbar bug fixes documented in BUGS3.md
# (applied in `src/widget_scrolling.cr` and `src/widget/scrollbar.cr`).

private def bugs3_screen(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w,
    height: h)
end

private def bugs3_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

describe "BUGS3 scrolling & scrollbar fixes" do
  # Fix #1 / #2: `scroll` and `clamp_child_base_to_content` must not advance
  # `@child_base` past content when the viewport has no visible content rows
  # (ivertical >= aheight, so `visible_content_rows == 0`).
  describe "collapsed viewport (visible_content_rows == 0)" do
    it "does not advance child_base when scrolling a fully-collapsed box" do
      s = bugs3_screen
      # A bordered box only 2 rows tall: border eats both rows, so
      # ivertical (2) >= aheight (2) and there are 0 visible content rows.
      st = Widget::ScrollableText.new(
        parent: s, top: 0, left: 0, width: 20, height: 2,
        style: Style.new(border: true))
      st.content = (1..50).map { |i| "row #{i}" }.join('\n')
      s.render

      st.child_base.should eq(0)

      # A large scroll must be a no-op: the base cannot climb past content when
      # nothing is visible.
      st.scroll 100
      st.child_base.should eq(0)

      # Even repeated large scrolls stay pinned at 0.
      st.scroll 1000
      st.child_base.should eq(0)
    end

    it "restores top-of-content visibility after the viewport is enlarged" do
      s = bugs3_screen
      st = Widget::ScrollableText.new(
        parent: s, top: 0, left: 0, width: 20, height: 2,
        style: Style.new(border: true))
      st.content = (1..50).map { |i| "row #{i}" }.join('\n')
      s.render

      # Scroll hard while collapsed (would previously push base past content).
      st.scroll 1000
      st.child_base.should eq(0)

      # Enlarge the viewport so content becomes visible again.
      st.height = 12
      s.render

      # Content is still visible from the top: the base was never pushed off.
      st.child_base.should eq(0)
      st.get_scroll_perc(false).should eq(0)
    end
  end

  # Fix #3 (REVERTED — BUGS3.md #3 was a false finding): `reset_scroll` must NOT
  # zero `@last_scroll_max`. `#stick_to_tail?` is `@child_base >= @last_scroll_max`
  # and the sticky-bottom contract is "pin to the tail only while ALREADY at the
  # tail." After a programmatic `reset_scroll` the view is at the *top*, so it must
  # stay there as content grows. Because reset leaves `@child_base == 0` while
  # `@last_scroll_max` retains its old positive value, `0 >= positive` is false —
  # correctly "not at the tail." Zeroing it (the reported "fix") would make
  # `0 >= 0` true and snap a follow-tail Log to the bottom, i.e. the exact yank the
  # report claimed to prevent. This spec locks in the correct behavior.
  describe "reset_scroll keeps a follow-tail view at the top" do
    it "does not yank a follow-tail Log to the bottom after a reset-to-top" do
      s = bugs3_screen 20, 5
      log = Widget::Log.new parent: s, top: 0, left: 0, width: 20, height: 5
      log.follow_tail?.should be_true

      # Grow content until it sticks to the tail.
      20.times { |i| log.add "line #{i}" }
      s.render
      log.get_scroll_perc(false).should be >= 100

      # Programmatic reset to the top.
      log.reset_scroll
      s.render
      log.child_base.should eq(0)

      # More content arrives: a reset-to-top must be preserved, so the view stays
      # at the top rather than being yanked back to the bottom.
      10.times { |i| log.add "more #{i}" }
      s.render

      log.child_base.should eq(0)
      log.get_scroll_perc(false).should be < 100
    end
  end

  # Fix #4: a standalone ScrollBar with `tracking? == false` captures the mouse
  # on an untracked seek, so a release *off* the bar still commits `@value`.
  describe "standalone ScrollBar untracked drag committed off-bar" do
    it "commits @value on a release that lands outside the bar's rect" do
      s = bugs3_screen 40, 20
      bar = Widget::ScrollBar.new(
        parent: s, orientation: :vertical,
        top: 0, left: 0, width: 1, height: 10,
        minimum: 0, maximum: 100)
      bar.tracking = false
      s.render

      bar.value.should eq(0)

      # Press near the bottom of the bar's trough: an untracked seek sets
      # `slider_position` but does NOT commit `value`, and captures the mouse.
      s.dispatch_mouse bugs3_mouse(::Tput::Mouse::Action::Down, 0, 9)
      bar.value.should eq(0)            # not committed yet (tracking off)
      bar.slider_position.should be > 0 # thumb moved

      # Release well off the bar (x=30, y=30). Thanks to the capture, the bar's
      # handler still receives this `up` and commits the pending value.
      s.dispatch_mouse bugs3_mouse(
        ::Tput::Mouse::Action::Up, 30, 30, ::Tput::Mouse::Button::None)

      bar.value.should be > 0
    end
  end
end
