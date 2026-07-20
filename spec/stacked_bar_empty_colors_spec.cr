require "./spec_helper"

include Crysterm

# `Widget::Graph::StackedBar#segment_color` cycles a per-level color with
# `@colors[level % @colors.size]`. Setting `colors` to an *empty* array made
# that `level % 0` — a `DivisionByZeroError` that crashed the render. Since
# segments are color-keyed (the method must return a non-nil String), an empty
# array now falls back to `DEFAULT_COLORS`.

private def sbec_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "Widget::Graph::StackedBar with an empty colors array" do
  it "renders without dividing by zero (falls back to the default palette)" do
    s = sbec_screen
    sb = Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0,
      width: 50, height: 10, maximum: 100.0, colors: [] of String
    sb.values = [[60, 30, 10], [20, 50, 30], [80, 15, 5]]

    # Before the fix this raised DivisionByZeroError inside build_content.
    s.repaint

    # The plot renders, colored from DEFAULT_COLORS (so color tags are emitted).
    sb.content.should_not be_empty
    sb.content.should contain "{#{Crysterm::Widget::Graph::StackedBar::DEFAULT_COLORS[0]}-fg}"
  end
end
