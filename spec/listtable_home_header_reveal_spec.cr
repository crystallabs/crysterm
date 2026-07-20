require "./spec_helper"

include Crysterm

private def lth_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# A `ListTable` pins its header at screen row 0 (overlaying the spacer). When the
# selection jumps to the first data row from a scrolled position (Home / PageUp),
# the row must scroll *below* the header, not land under it (hidden). The `current_index=`
# override nudged the viewport before `super`, so `super`'s re-scroll put the row
# right back under the header.
describe Crysterm::Widget::ListTable do
  it "keeps the first data row visible below the header after jumping to top" do
    s = lth_window
    rows = [["Name"]] of Array(String)
    (1..20).each { |i| rows << ["Row#{i}"] }
    lt = Crysterm::Widget::ListTable.new parent: s, top: 0, left: 0, width: 20, height: 6, rows: rows
    s.repaint

    # Scroll far down, then jump back to the first data row (as Home does).
    lt.current_index = 18
    s.repaint
    lt.current_index = 1
    s.repaint

    lt.current_index.should eq 1
    # child_base must be 0 so item 1 sits at screen row 1 (below the header at
    # screen row 0), i.e. the selected row is not hidden under the header.
    lt.child_base.should eq 0
    (lt.current_index > lt.child_base).should be_true
  end
end
