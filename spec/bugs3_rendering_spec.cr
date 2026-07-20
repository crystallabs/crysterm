require "./spec_helper"

include Crysterm

# BUGS3: per-line starting-attribute fallback in a scrollable/wrapped text box.
#
# `src/widget_rendering.cr:194` resolves the attribute a scrolled/wrapped line
# *starts* with from the cached `@_clines.attr` array. When that cache entry is
# missing, the fallback must be the terminal DEFAULT_ATTR (default fg on default
# bg), NOT a packed `0_i64` — which decodes to fg=0x000000 on bg=0x000000, i.e.
# black-on-black (invisible text).

private def headless(w, h)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "BUGS3: scrollable text box per-line attr fallback" do
  # Lock in the invariant the fix relies on: the DEFAULT_ATTR the fallback now
  # uses is *not* a packed zero, and the two decode to different colors.
  it "distinguishes DEFAULT_ATTR from a packed-0 (black-on-black) attr" do
    # A packed-0 attr decodes to concrete black fg on black bg.
    Attr.fg(0_i64).should eq 0_i64
    Attr.bg(0_i64).should eq 0_i64
    Attr.unpack_color(Attr.fg(0_i64)).should eq 0x000000
    Attr.unpack_color(Attr.bg(0_i64)).should eq 0x000000

    # DEFAULT_ATTR must NOT be zero...
    Window::DEFAULT_ATTR.should_not eq 0_i64
    # ...and both its color fields must be the terminal-default sentinel, which
    # decodes to the logical -1 ("terminal default"), not black.
    Attr.default?(Attr.fg(Window::DEFAULT_ATTR)).should be_true
    Attr.default?(Attr.bg(Window::DEFAULT_ATTR)).should be_true
    Attr.unpack_color(Attr.fg(Window::DEFAULT_ATTR)).should eq -1
    Attr.unpack_color(Attr.bg(Window::DEFAULT_ATTR)).should eq -1
  end

  # End-to-end: a scrolled text box whose per-line attr cache is missing must
  # render its lines with the default attr (default fg/bg), never black-on-black.
  it "renders a scrolled line with the default attr, not black-on-black" do
    s = headless 20, 5
    # Content taller than the box, so it wraps/scrolls and `ci > 0` for the
    # rendered lines (the branch guarding the line-194 fallback).
    lines = (1..20).map { |i| "line #{i}" }.join('\n')
    b = Widget::ScrollableText.new(
      parent: s, top: 0, left: 0, width: 20, height: 5, content: lines)

    # Scroll down so the first rendered line is a non-first content line
    # (coords.base > 0 -> the `ci > 0` fallback branch is exercised).
    b.scroll 10
    s.repaint

    # Drop the cached per-line attr array to force the fallback branch, then
    # re-render. With the fix this yields DEFAULT_ATTR; before it, `0_i64`.
    b._clines.attr = nil
    s.repaint

    pos = b.last_rendered_position
    # Inspect the top-left content cell of the rendered box.
    cell = s.lines[pos.yi][pos.xi]

    # The rendered cell must not be black-on-black. Its background must be the
    # terminal default, exactly as DEFAULT_ATTR provides.
    cell.attr.should_not eq 0_i64
    Attr.default?(Attr.bg(cell.attr)).should be_true
    Attr.unpack_color(Attr.bg(cell.attr)).should eq -1
  end
end
