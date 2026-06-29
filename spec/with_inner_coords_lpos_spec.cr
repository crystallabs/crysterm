require "./spec_helper"

include Crysterm

# Regression coverage for `Widget#with_inner_coords` (`widget_rendering.cr`).
#
# Widgets that paint their own interior on top of the standard render — a
# `Gradient`, `ProgressBar`, `Slider`, `Dial`, `ScrollBar`, `Marquee`, … — drive
# their `#render` through `with_inner_coords`, which insets the rendered
# rectangle by the border and yields the *interior* to the block.
#
# That inset must NOT corrupt the widget's cached position: the object handed to
# the block is the very `@lpos` `_render` just stored (and returns), and
# `Border#adjust(pos)` shrinks it *in place*. The bug left `@lpos` collapsed to
# the interior after every render, so until the next frame recomputed it, every
# reader of the cached position (mouse hit-testing via `last_rendered_position`,
# damage-tracking subtree bounds, `clear_last_rendered_position`) saw the widget
# as border-smaller than it actually painted.
private def render_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 8)
end

describe "Widget#with_inner_coords cached position" do
  it "leaves the widget's @lpos describing the full outer rect, not the border interior" do
    screen = render_screen
    g = Widget::Gradient.new(
      colors: ["#ff0000", "#00ff00"],
      parent: screen, top: 0, left: 0, width: 10, height: 5)
    # All-sides line border (1 cell per side).
    g.style.border = true

    screen._render

    lp = g.last_rendered_position
    # The cached position must span the whole widget (10x5), NOT the
    # border-inset interior (8x3).
    lp.awidth.should eq 10
    lp.aheight.should eq 5
    (lp.xl - lp.xi).should eq 10
    (lp.yl - lp.yi).should eq 5
  end
end
