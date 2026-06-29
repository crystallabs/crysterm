require "./spec_helper"

include Crysterm

# `Mixin::TextEditing#_update_cursor` (non-wrapping editing path) must let the
# caret sit in the one extra right-edge column that `#content_margin_x` reserves
# "so the caret has somewhere to sit at the end of a full-width line".
#
# When a value is WIDER than the viewport and the caret is at the very end,
# `#ensure_visible_x` can only scroll the horizontal base to
# `full_width - content_width`, leaving the caret at display offset
# `content_width` — i.e. the reserved column. The placement clamp used to cap at
# `content_width - 1`, drawing the caret one column too far left (on the last
# visible character instead of in the reserved column after it).
describe "Mixin::TextEditing caret in the reserved end column" do
  it "places an end-of-line caret in the reserved column when the line overflows" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 30, height: 10)

    pte = Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 8, height: 3
    pte.wrap_content = false # engage the non-wrapping (horizontal-scroll) path

    # 12 columns of content in an 8-column box: the interior is 8 columns, of
    # which `content_margin_x` (== 1 here) reserves the rightmost for the caret,
    # so `content_width` is 7. Setting the value parks the caret at the end and
    # scrolls the base to `full_width - content_width == 12 - 7 == 5`.
    pte.value = "abcdefghijkl"
    pte.focus
    s.render

    pte.content_width.should eq 7
    pte.child_base_x.should eq 5

    pte._update_cursor

    # Caret display column is 12; minus the base 5 = offset 7, the reserved
    # column (left == 0). Previously clamped to 6 — on the last visible char.
    s.tput.cursor.x.should eq 7
  end

  it "leaves an end-of-line caret put when the whole line fits" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 30, height: 10)

    pte = Widget::PlainTextEdit.new parent: s, top: 0, left: 0, width: 8, height: 3
    pte.wrap_content = false
    pte.value = "abc"
    pte.focus
    s.render

    pte.child_base_x.should eq 0
    pte._update_cursor

    # Content fits, so no horizontal scroll: the caret sits right after "abc".
    s.tput.cursor.x.should eq 3
  end
end
