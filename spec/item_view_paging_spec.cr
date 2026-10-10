require "./spec_helper"

include Crysterm

# Page Up/Down in item views turn the *viewport* by a page and select the first
# (Page Down) / last (Page Up) item of the new page, as in vi, less and mutt.
# The previous behavior moved the selection by a page and let the view follow,
# so the first press parked the selection on the bottom row without scrolling.

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
  it "scrolls a page on the first press and selects the new page's first/last item" do
    _, list = paging_list
    list.current_index.should eq 0
    list.child_base.should eq 0

    press list, Tput::Key::PageDown
    list.child_base.should eq 6    # the view turned a page at once
    list.current_index.should eq 6 # first item of it

    press list, Tput::Key::PageDown
    list.child_base.should eq 12
    list.current_index.should eq 12

    press list, Tput::Key::PageUp
    list.child_base.should eq 6
    list.current_index.should eq 11 # last visible item

    press list, Tput::Key::PageUp
    list.child_base.should eq 0
    list.current_index.should eq 5
  end

  it "selects the first/last item when the view is already at that end" do
    _, list = paging_list
    list.current_index = 3
    press list, Tput::Key::PageUp
    list.child_base.should eq 0
    list.current_index.should eq 0

    list.current_index = 29
    base = list.child_base
    list.current_index = 26
    press list, Tput::Key::PageDown
    list.child_base.should eq base
    list.current_index.should eq 29
  end

  it "pages by rows and selects the item at the new page's edge when spaced" do
    _, list = paging_list(1)
    press list, Tput::Key::PageDown
    list.child_base.should eq 6
    list.current_index.should eq 3 # row 6 holds item 3 (row = 2 * index)
    press list, Tput::Key::PageUp
    list.child_base.should eq 0
    list.current_index.should eq 2 # last item fully on rows 0..5 is item 2 (row 4)
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
    lt.child_base.should be > 0
    lt.current_index.should be > 1
    press lt, Tput::Key::PageUp
    press lt, Tput::Key::PageUp
    lt.current_index.should eq 1
    lt.child_base.should eq 0
  end
end
