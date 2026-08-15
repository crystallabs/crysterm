require "./spec_helper"

include Crysterm

# BUGS15 #85 regression: content-sized Table/ListTable must not feed their own
# self-pinned width back into `compute_column_widths`.
#
# `#rows=`/`#paint` pin `@width = row_width + ihorizontal (+ scrollbar reserve)`
# so the box always fits every column. But `compute_column_widths` takes its
# slack-distribution branch whenever `@width` is a numeric `Int32`, so once
# pinned, a content-sized table (a) can never shrink when its data gets
# narrower, and (b) — with the vertical scroll bar shown — folds the bar's
# reserve column into the column widths and grows one column per refresh,
# unbounded. The pinned width is cleared before each remeasure for
# content-sized tables only; fixed-width tables keep distributing slack.

describe "BUGS15 #85 content-sized table sizing" do
  it "shrinks a content-sized Table when its data gets narrower" do
    s = headless_screen(40, 20, default_quit_keys: true)
    t = Crysterm::Widget::Table.new parent: s, rows: [["a very long header cell"]]

    wide = t.width_spec
    wide.should be_a(Int32)

    # Narrow the data. Width must fall back to the short-content width, i.e. the
    # width of a table freshly constructed with the same short data.
    t.rows = [["x"]]

    fresh = Crysterm::Widget::Table.new parent: s, rows: [["x"]]

    t.width_spec.should eq(fresh.width_spec)
    t.width_spec.as(Int32).should be < wide.as(Int32)

    # Rendering must not re-grow it either.
    s.repaint
    t.width_spec.should eq(fresh.width_spec)
  end

  it "keeps a scrolling content-sized ListTable's width constant across refreshes" do
    s = headless_screen(40, 20, default_quit_keys: true)
    data = (0...21).map { |i| ["row#{i}", "b"] }
    lt = Crysterm::Widget::ListTable.new parent: s, height: 5, rows: data
    # Force the vertical scroll bar so its reserve column is in play.
    lt.scrollbar_policy = Crysterm::Widget::ScrollBarPolicy::AlwaysOn

    widths = [] of Int32
    5.times do
      s.repaint
      widths << lt.width_spec.as(Int32)
      lt.rows = data # identical data, refreshed
    end

    # In the bug this grew 1 column per refresh (17→18→19→20→21→22).
    widths.uniq.size.should eq(1)
  end

  it "keeps a fixed-width Table distributing slack (width stays fixed)" do
    s = headless_screen(60, 20, default_quit_keys: true)
    t = Crysterm::Widget::Table.new(
      parent: s,
      width: 30,
      rows: [["Name", "City"], ["Al", "NY"]])

    t.width_spec.should eq(30)

    # New (still-narrow) data must not change the fixed width — the slack is
    # redistributed across the columns as before.
    t.rows = [["A", "B"], ["c", "d"]]
    t.width_spec.should eq(30)

    s.repaint
    t.width_spec.should eq(30)
  end
end
