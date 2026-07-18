require "./spec_helper"

include Crysterm

# Regression for `Widget#scroll_percent`'s degenerate divisor: the percentage
# is `(child_base + child_offset) / (scroll_height - 1)`. When
# `scroll_height == 1`, the span `i - 1` is 0 and division yields
# Infinity/NaN, propagating a garbage percentage. Reached with a single
# content line and visible height <= 0 (e.g. a height-1 widget whose border
# consumes the whole interior). Must return 0.0 (top == bottom), never NaN/Infinity.

private def sp_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

describe "Widget#scroll_percent" do
  it "returns a finite, sane percentage in the degenerate single-line case" do
    s = sp_screen
    # height 1 + border ⇒ ivertical 2 ⇒ visible height -1; single content line
    # ⇒ scroll_height == 1 ⇒ the `i - 1 == 0` span.
    w = Widget.new parent: s, top: 0, left: 0, width: 20, height: 1,
      style: Crysterm::Style.new(border: true), scrollable: true, content: "only line"
    s.render

    w.scroll_height.should eq 1

    perc = w.scroll_percent
    perc.to_f.finite?.should be_true # never Infinity/NaN
    perc.should eq 0                 # top == bottom ⇒ 0.0

    w.scroll_percent.to_f.finite?.should be_true
  end

  it "still reports the normal multi-line percentage (0.0 at top, 1.0 at bottom)" do
    s = sp_screen
    st = Widget::ScrollableText.new parent: s, top: 0, left: 0, width: 20, height: 5
    st.content = (1..30).map { |i| "row #{i}" }.join('\n')
    s.render

    st.scroll_percent.should eq 0 # at the top

    st.scroll_percent = 1.0
    s.render
    st.scroll_percent.should be >= 1.0 # fully scrolled
  end
end
