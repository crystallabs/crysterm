require "./spec_helper"

include Crysterm

# Regression for `Widget#get_scroll_perc`'s degenerate divisor: the percentage
# is `(child_base + child_offset) / (get_scroll_height - 1) * 100`. When
# `get_scroll_height == 1`, the span `i - 1` is 0 and division yields
# Infinity/NaN, propagating a garbage percentage. Reached with a single
# content line and visible height <= 0 (e.g. a height-1 widget whose border
# consumes the whole interior). Must return 0% (top == bottom), never NaN/Infinity.

private def sp_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

describe "Widget#get_scroll_perc" do
  it "returns a finite, sane percentage in the degenerate single-line case" do
    s = sp_screen
    # height 1 + border ⇒ iheight 2 ⇒ visible height -1; single content line
    # ⇒ get_scroll_height == 1 ⇒ the `i - 1 == 0` span.
    w = Widget.new parent: s, top: 0, left: 0, width: 20, height: 1,
      style: Crysterm::Style.new(border: true), scrollable: true, content: "only line"
    s.render

    w.get_scroll_height.should eq 1

    perc = w.get_scroll_perc(false)
    perc.to_f.finite?.should be_true # never Infinity/NaN
    perc.should eq 0                 # top == bottom ⇒ 0%

    # `s == true` variant must also stay finite (no crash, no garbage).
    w.get_scroll_perc(true).to_f.finite?.should be_true
  end

  it "still reports the normal multi-line percentage (0 at top, 100 at bottom)" do
    s = sp_screen
    st = Widget::ScrollableText.new parent: s, top: 0, left: 0, width: 20, height: 5
    st.content = (1..30).map { |i| "row #{i}" }.join('\n')
    s.render

    st.get_scroll_perc(false).should eq 0 # at the top

    st.set_scroll_perc 100
    s.render
    st.get_scroll_perc(false).should be >= 100 # fully scrolled
  end
end
