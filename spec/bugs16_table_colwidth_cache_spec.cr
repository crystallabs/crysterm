require "./spec_helper"

include Crysterm

# BUGS16 B16-34 regression: the column-width cache (`@maxes`) is keyed only by
# `@maxes_dirty`, which `#rows=`/`#column_spacing=` trip — but the computed
# widths also depend on the interior width `@width - ihorizontal`. When the CSS
# cascade first adds a border/padding (after the constructor's `#rows=`, with no
# `Resize` since the outer `@width` is unchanged), nothing marks the cache
# dirty, so the columns permanently fill the *pre-cascade* interior — `ihorizontal`
# columns too wide. The fix also keys the cache on `{@width, ihorizontal,
# @column_spacing}` so it recomputes exactly when a dependency moved.

private def headless_window(width = 60, height = 20)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

describe "BUGS16 B16-34 table column-width cache invalidation on inset change" do
  it "keeps a fixed-width Table honoring its width after CSS adds a border" do
    s = headless_window
    t = Crysterm::Widget::Table.new(
      parent: s, top: 0, left: 0,
      width: 40, rows: [["Name", "Score"], ["Alice", "10"]])

    # Border comes in via the cascade, after the ctor's `#rows=` ran with
    # `ihorizontal == 0`.
    s.stylesheet = "Table { border: solid; }"
    s._render

    # The fixed width must be honored: render re-pins `@width = row_width +
    # ihorizontal`, which grows to 42 when `@maxes` are stale (computed for the
    # pre-cascade interior of 40 instead of 38).
    t.width.should eq(40)

    # A control table that had the border from construction distributes slack
    # over the real interior (38) — the stylesheet path must match it.
    control = Crysterm::Widget::Table.new(
      parent: s, top: 0, left: 0,
      width: 40, rows: [["Name", "Score"], ["Alice", "10"]],
      style: Crysterm::Style.new(border: true))
    s._render

    t.@maxes.should eq(control.@maxes)
    t.width.should eq(control.width)
  end

  it "sizes a fixed-width ListTable's rows to the post-cascade interior" do
    s = headless_window
    lt = Crysterm::Widget::ListTable.new(
      parent: s, top: 0, left: 0, height: 6,
      width: 40, rows: [["Name", "Score"], ["Alice", "10"]])

    s.stylesheet = "ListTable { border: solid; }"
    s._render

    # Interior is 40 - ihorizontal (2). Rows sized to the stale pre-cascade
    # interior (40) overflow the content edge by 2 columns.
    interior = 40 - lt.ihorizontal
    lt.row_width.should eq(interior)
    lt.overflows_x?.should be_false
  end
end
