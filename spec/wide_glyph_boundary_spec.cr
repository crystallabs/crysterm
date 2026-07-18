require "./spec_helper"

include Crysterm

# Regression (BUGS.md #8): a wide (2-column) grapheme whose lead cell lands on
# the LAST content column has no room for its continuation cell inside the
# content region. The renderer's continuation claim is gated on `x + 1 < xl`,
# so it used to leave a width-2 glyph at the boundary with real content (the
# border) in the very next column. `draw` (window_drawing) then claimed that
# neighbor as a continuation purely from the lead cell's width — corrupting the
# border cell and desyncing cell-index from terminal column.
#
# This is reachable whenever the content area is narrower than a leading wide
# glyph: `wrap_cut_index` only cuts *before* a wide cluster once some content is
# already placed (`total > 0`), so a wide glyph with nothing before it is forced
# into a too-narrow region rather than dropped. A 1-column content area (a
# width-3 bordered box) is the minimal trigger.
#
# The fix blanks an unshowable half-glyph to a space at render time, preserving
# the invariant "a width-2 cell is always followed by an in-region continuation".

private def fu_screen(width, height)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
  s.full_unicode = true
  pending! "full_unicode unavailable in this environment" unless s.full_unicode_effective?
  s
end

describe "wide glyph at a content boundary" do
  # A width-3 bordered box has a 1-column content area (x=1, xl=2). A wide glyph
  # can't fit, and the content pipeline can't cut before it, so it reaches the
  # renderer at the last content column.
  it "blanks a wide glyph too wide for a 1-column content area, sparing the border" do
    s = fu_screen(5, 3)
    Widget::Box.new parent: s, top: 0, left: 0, width: 3, height: 3,
      content: "漢", style: Style.new(border: true)
    s._render
    line = s.lines[1] # content row (row 0 is the top border)

    line[1].char.should eq ' ' # lead cell blanked, not '漢'
    line[1].width.should eq 1
    line[1].continuation?.should be_false
    line[1].grapheme_overlay.should be_nil

    # The border column is NOT over-claimed as a continuation.
    line[2].char.should eq '│'
    line[2].continuation?.should be_false
  end

  # Control: given room for the continuation, the wide glyph lays across two
  # cells as usual and the following cell is its continuation.
  it "lays a wide glyph across two cells when the continuation fits" do
    s = fu_screen(6, 3)
    Widget::Box.new parent: s, top: 0, left: 0, width: 6, height: 3,
      content: "漢z", style: Style.new(border: true) # content cols x=1..4
    s._render
    line = s.lines[1]

    line[1].char.should eq '漢'
    line[1].width.should eq 2
    line[2].continuation?.should be_true
    line[3].char.should eq 'z'
  end

  # The invariant across a broad sweep of narrow bordered boxes, wrap on/off, and
  # horizontal scroll offsets: no width-2 cell is ever left without an in-region
  # continuation cell immediately after it. (Fails on every buggy combination
  # before the fix; the search surfaced 91.)
  it "never leaves a width-2 cell without an in-region continuation" do
    {"aあ漢い", "😀😀😀", "漢漢漢漢"}.each do |content|
      (3..6).each do |w|
        (0..4).each do |sx|
          {true, false}.each do |wrap|
            s = fu_screen(w + 3, 4)
            b = Widget::Box.new parent: s, top: 0, left: 0, width: w, height: 4,
              content: content, style: Style.new(border: true)
            b.wrap_content = wrap
            b.child_base_x = sx unless wrap
            s._render
            s.lines.each do |line|
              (0...(w - 1)).each do |x|
                if line[x].width == 2
                  line[x + 1].continuation?.should be_true
                end
              end
            end
          end
        end
      end
    end
  end
end
