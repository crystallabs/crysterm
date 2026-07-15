require "./spec_helper"

include Crysterm

# Regression specs for the BUGS5 fixes:
#
#   * BUG 1 — `Widget#set_scroll_perc` mapped against the full content height
#     while `#get_scroll_perc` divides by the scrollable *range*, so the two
#     were not inverses and `Log#scroll_percentage = Log#scroll_percentage`
#     jumped the view. (`src/widget_scrolling.cr`)
#   * BUG 2 — `ListTable#select_index` guarded only the exact index `0`, so a negative
#     index (PageUp / Ctrl-B / Ctrl-U near the top) clamped to `0` in the parent
#     and landed on the unselectable header spacer. (`src/widget/listtable.cr`)
#   * BUG 3 — `Mixin::ItemView` scroll/selection math used the bare item index as
#     a content row, ignoring `item_spacing`, so selecting an item in a spaced,
#     overflowing list left it off-screen. (`src/mixin/item_view.cr` +
#     `_scroll_bottom` spaced extent)

private def bugs5_screen(w = 40, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS5 scrolling & item-view fixes" do
  # BUG 1: percentage round-trip must be idempotent for an @always_scroll widget.
  describe "Log#scroll_percentage round-trip is idempotent (set inverts get)" do
    it "does not move child_base when re-applying the current percentage" do
      s = bugs5_screen 30, 24
      log = Widget::Log.new parent: s, top: 0, left: 0, width: 30, height: 20
      # Sticky-bottom would clamp/yank the base; disable it so we test a fixed
      # mid-content position.
      log.follow_tail = false
      100.times { |i| log.add "ln#{i}" }
      s.render

      # Park mid-content and lay out so `@lpos` (used by `get_scroll_perc`) is set.
      log.child_base = 40
      s.render
      log.child_base.should eq(40)

      # The heart of the bug: `w.scroll_percentage = w.scroll_percentage` must be
      # a no-op. Pre-fix, get returned 40/(100-20)=50% but set did
      # `scroll_to(0.5 * 100) = scroll_to(50)`, jumping the base 40 -> 50.
      log.scroll_percentage = log.scroll_percentage
      log.child_base.should eq(40)
    end
  end

  # BUG 2: a negative select_index index must clamp to the first data row, never the
  # header spacer at index 0.
  describe "ListTable#select_index clamps a negative index to the first data row" do
    it "does not select the header spacer on page-up near the top" do
      s = bugs5_screen 40, 24
      rows = [["Name", "Age"]]
      (1..20).each { |i| rows << ["person#{i}", i.to_s] }
      lt = Widget::ListTable.new parent: s, top: 0, left: 0, width: 24, height: 6, rows: rows
      s.render

      lt.select_index 3
      lt.selected.should eq(3)

      # PageUp / Ctrl-B near the top does `select_index(selected - visible)`, which is
      # negative. Pre-fix that clamped to 0 (the header spacer), making @value "".
      lt.select_index(3 - 10)
      lt.selected.should be >= 1
      lt.value.should_not eq("")
    end
  end

  # BUG 3: with item_spacing > 0, selecting an item in an overflowing list must
  # scroll so the item's *spaced* content row is visible.
  describe "ItemView selection honors item_spacing when scrolling" do
    it "keeps the selected item on-screen in a spaced, overflowing list" do
      s = bugs5_screen 40, 24
      items = (0...20).map { |i| "item#{i}" }
      list = Widget::List.new parent: s, top: 0, left: 0, width: 20, height: 5, items: items
      list.item_spacing = 1
      # `_render` (not `render`) actually lays the list out and sets `@lpos`;
      # `select_index`'s scroll path is gated on `@lpos`, so a bare `render` would skip it.
      s._render

      # Select the last item. With spacing 1 it sits at content row 19*2 == 38.
      list.select_index 19
      list.selected.should eq(19)

      visible = 5                                   # borderless height
      row = list.selected * (1 + list.item_spacing) # item_row(selected) == 38
      # The item's spaced row must fall inside [child_base, child_base + visible).
      # Pre-fix, `scroll_to @selected` left child_base ~15 (item_row not applied
      # and _scroll_bottom == items.size), so row 38 was far off-screen.
      list.child_base.should be <= row
      (list.child_base + visible).should be > row
    end
  end
end
