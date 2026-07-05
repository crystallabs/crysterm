require "./spec_helper"

include Crysterm

# `Widget::Graph::Bar#bar_color` cycles a per-bar color with `colors[i % size]`.
# An *empty* `colors` array (a natural "no custom colors, use style.fg" input,
# which the `nil` case already handles) is truthy, so the guard `c ? ... : nil`
# fell through to `i % 0` — a `DivisionByZeroError` that crashed the render.
# An empty array now behaves like `nil` (no per-bar color).

private def bec_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "Widget::Graph::Bar with an empty colors array" do
  it "renders without dividing by zero (treats empty colors like nil)" do
    s = bec_screen
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0,
      width: 40, height: 8, max: 100.0, colors: [] of String
    bar.values = [42, 88, 13, 64]

    # Before the fix this raised DivisionByZeroError inside build_content.
    s._render

    # The plot renders (glyphs present), just without per-bar coloring.
    bar.content.should_not be_empty
    bar.content.should_not contain "-fg}" # no color tags emitted
  end
end
