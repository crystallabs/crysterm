require "./spec_helper"

include Crysterm

# Regression for the BCE (back-color-erase) clear-to-end-of-line path in
# `Window#draw` (`window_drawing.cr`).
#
# When a line is "colored/styled content followed by a default-attribute space
# tail", the draw loop emits the leading content (leaving the terminal's SGR set
# to that content's attribute) and then clears the tail with `el`. Setting up
# the clear used `Screen.write_sgr`, which writes an attribute from a
# *blank* SGR state and emits nothing for the default attribute — so the
# transition from the non-default leading attribute to the default clear
# attribute emitted no bytes, the `el` erased the tail under the stale
# background (BCE), and the leftover SGR bled into whatever was drawn next. Fix
# emits an explicit reset (`\e[m`) first, like the per-cell emission path does.
#
# Observable headlessly: with BCE enabled, draw a row of bold leading cells plus
# a bold-space tail (so the tail is bold in `@flushed_lines`), then redraw with the
# tail turned back to plain default spaces while the leading cells change (so
# they're re-emitted, leaving the terminal in the bold SGR state when the clear
# begins). Bold emits `\e[1m` regardless of color depth, so the scenario is
# deterministic. The clear must reset to default (bare `\e[m`) before `el`;
# that reset is absent in the buggy output.
private def bce_screen(output, width = 12, height = 2)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
  s.optimization = Crysterm::OptimizationFlag::BCE
  s.alloc
  s
end

describe "Window#draw BCE clear-to-EOL" do
  it "resets the terminal SGR before erasing the line when leading cells are styled" do
    obuf = IO::Memory.new
    s = bce_screen obuf
    w = s.awidth
    y = 0
    bold = Attr.pack(Attr::BOLD.to_i64, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)
    default = s.default_attr

    # Prime: @flushed_lines mirrors the (all-default) buffer.
    s.draw

    # Frame A: leading bold 'X' cells, and a bold-space tail. After this the
    # tail in @flushed_lines is bold spaces (differs from screen default), which is
    # what makes the next frame's clear actually need to fire.
    (0...5).each do |x|
      c = s.lines[y][x]; c.attr = bold; c.char = 'X'
    end
    (5...w).each do |x|
      c = s.lines[y][x]; c.attr = bold; c.char = ' '
    end
    s.lines[y].dirty = true
    s.draw

    # Frame B: change the leading cells (so they're re-emitted, leaving the
    # terminal in bold SGR state) and turn the tail back to plain default
    # spaces (so the BCE clear-to-EOL path fires for the tail).
    obuf.clear
    (0...5).each do |x|
      c = s.lines[y][x]; c.attr = bold; c.char = 'Y'
    end
    (5...w).each do |x|
      c = s.lines[y][x]; c.attr = default; c.char = ' '
    end
    s.lines[y].dirty = true
    s.draw

    emitted = String.new(obuf.to_slice)

    # Sanity: the clear path actually ran this frame.
    emitted.empty?.should be_false
    # The leading bold cells were re-emitted with `\e[1m`...
    emitted.includes?("\e[1m").should be_true
    # ...and before the line was erased back to default, the SGR must have
    # been reset. Without the fix no reset is emitted, so `el` would erase
    # under the still-active bold attribute.
    emitted.includes?("\e[m").should be_true
  end
end
