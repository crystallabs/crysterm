require "./spec_helper"

# A non-ASCII row's codepoint index is kept across frames while the row's
# `String` stays the same object; a changed row rebuilds its slot.
describe "base_render row index cache" do
  it "reuses the index of an unchanged non-ASCII row and rebuilds a replaced one" do
    s = headless_screen(30, 6)
    box = Crysterm::Widget::Box.new parent: s, width: 12, height: 3, content: "café — über\nplain ascii\nñandú"
    s.repaint
    cache = box.@_row_indexes.not_nil!
    cache.size.should eq 3 # slots 0..2 (slot 1 holds a filler for the ASCII row)
    first = cache[0]
    first.object.same?(box.wrapped_lines[0]).should be_true
    cache[2].object.same?(box.wrapped_lines[2]).should be_true
    s.repaint
    box.@_row_indexes.not_nil![0].object.same?(first.object).should be_true
    (0...11).map { |x| s.cell_rows[0][x].char }.join.should eq "café — über"
    (0...5).map { |x| s.cell_rows[2][x].char }.join.should eq "ñandú"

    box.content = "naïve\nplain ascii\nñandú"
    s.repaint
    cache = box.@_row_indexes.not_nil!
    cache[0].object.same?(box.wrapped_lines[0]).should be_true
    cache[0].object.same?(first.object).should be_false
    (0...5).map { |x| s.cell_rows[0][x].char }.join.should eq "naïve"
  ensure
    s.try &.destroy
  end

  it "leaves an all-ASCII widget without a cache" do
    s = headless_screen(30, 6)
    box = Crysterm::Widget::Box.new parent: s, width: 12, height: 3, content: "plain\ntext"
    s.repaint
    box.@_row_indexes.should be_nil
  ensure
    s.try &.destroy
  end
end
