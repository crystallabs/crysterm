require "./spec_helper"

include Crysterm

# Page Up/Down in item views move the selection by a page — one item short of
# the viewport — and the view follows it, as `QListView` does: from the top
# row the first Page Down lands on the last visible item without scrolling,
# and each further press turns the view a page.

private def paging_list(spacing = 0)
  s = headless_screen(40, 10)
  list = Widget::List.new parent: s, top: 0, left: 0, width: 20, height: 6,
    items: (1..30).map { |i| "item #{i}" }
  list.item_spacing = spacing
  s.repaint
  {s, list}
end

private def press(w, key : Tput::Key)
  w.emit Crysterm::Event::KeyPress.new('\0', key)
end

describe "Widget::List Page Up/Down" do
  it "lands on the last visible item first, then scrolls a page per press" do
    _, list = paging_list
    list.current_index.should eq 0
    list.child_base.should eq 0

    press list, Tput::Key::PageDown
    list.current_index.should eq 5 # the last visible item
    list.child_base.should eq 0    # no scroll yet

    press list, Tput::Key::PageDown
    list.current_index.should eq 10
    list.child_base.should eq 5 # the view followed

    press list, Tput::Key::PageUp
    list.current_index.should eq 5
    list.child_base.should eq 5 # still visible

    press list, Tput::Key::PageUp
    list.current_index.should eq 0
    list.child_base.should eq 0
  end

  it "stops at the first/last item" do
    _, list = paging_list
    list.current_index = 3
    press list, Tput::Key::PageUp
    list.child_base.should eq 0
    list.current_index.should eq 0

    list.current_index = 26
    press list, Tput::Key::PageDown
    list.current_index.should eq 29
  end

  it "pages by items that fit, not rows, when spaced" do
    _, list = paging_list(1)
    press list, Tput::Key::PageDown
    list.current_index.should eq 2 # 3 items fit in 6 rows; one short of that
    list.child_base.should eq 0
    press list, Tput::Key::PageDown
    list.current_index.should eq 4
    list.child_base.should be > 0
  end
end

describe "Widget::ListTable Page Up/Down" do
  it "turns pages and never selects the header row" do
    s = headless_screen(80, 24)
    rows = [["Name"]] of Array(String)
    (1..40).each { |i| rows << ["Row#{i}"] }
    lt = Widget::ListTable.new parent: s, top: 0, left: 0, width: 20, height: 6, rows: rows
    s.repaint

    press lt, Tput::Key::PageDown
    press lt, Tput::Key::PageDown
    lt.child_base.should be > 0
    lt.current_index.should be > 1
    press lt, Tput::Key::PageUp
    press lt, Tput::Key::PageUp
    lt.current_index.should eq 1
    lt.child_base.should eq 0
  end
end
