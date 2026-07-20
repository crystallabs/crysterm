require "./spec_helper"

include Crysterm

private def bugs3_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# The body cell values of a `ListTable`'s given column, in visible order
# (skipping the header at row 0). `rows` holds the ingested/sorted data.
private def body_column(lt : Crysterm::Widget::ListTable, col : Int32) : Array(String)
  lt.rows[1..].map { |r| r[col] }
end

describe "ListTable sort persistence and selection restore (BUGS3 fix #1/#2/#3)" do
  # Fix #1: sorting is re-applied on every data change, so data set *after*
  # `sort_by_column` is also shown sorted, not in raw ingest order.
  describe "sort is re-applied on data change" do
    it "sorts the initial body and keeps new data sorted (ascending)" do
      s = bugs3_screen
      lt = Crysterm::Widget::ListTable.new(
        parent: s,
        rows: [
          ["Name", "Score"],
          ["Charlie", "3"],
          ["Alice", "1"],
          ["Bob", "2"],
        ])

      lt.sort_by_column 0
      body_column(lt, 0).should eq ["Alice", "Bob", "Charlie"]

      # Fresh, unsorted data ingested after the sort must still come out sorted.
      lt.rows = ([
        ["Name", "Score"],
        ["Zoe", "9"],
        ["Mia", "5"],
        ["Ada", "1"],
      ])
      body_column(lt, 0).should eq ["Ada", "Mia", "Zoe"]
    end

    it "keeps new data sorted descending" do
      s = bugs3_screen
      lt = Crysterm::Widget::ListTable.new(
        parent: s,
        rows: [
          ["Name", "Score"],
          ["Bob", "2"],
          ["Alice", "1"],
          ["Charlie", "3"],
        ])

      lt.sort_by_column 0, order: :descending
      body_column(lt, 0).should eq ["Charlie", "Bob", "Alice"]

      lt.rows = ([
        ["Name", "Score"],
        ["Ada", "1"],
        ["Zoe", "9"],
        ["Mia", "5"],
      ])
      body_column(lt, 0).should eq ["Zoe", "Mia", "Ada"]
    end

    it "sorts a numeric column numerically, not lexically" do
      s = bugs3_screen
      lt = Crysterm::Widget::ListTable.new(
        parent: s,
        rows: [
          ["Name", "Score"],
          ["A", "10"],
          ["B", "2"],
          ["C", "1"],
        ])

      lt.sort_by_column 1
      # Numeric order (1, 2, 10), not lexical ("1", "10", "2").
      body_column(lt, 1).should eq ["1", "2", "10"]

      lt.rows = ([
        ["Name", "Score"],
        ["X", "100"],
        ["Y", "9"],
        ["Z", "20"],
      ])
      body_column(lt, 1).should eq ["9", "20", "100"]
    end

    it "records sort state so re-ingest via rows= keeps sorting" do
      s = bugs3_screen
      lt = Crysterm::Widget::ListTable.new(
        parent: s,
        rows: [
          ["Name", "Score"],
          ["Charlie", "3"],
          ["Alice", "1"],
          ["Bob", "2"],
        ])

      lt.sort_by_column 0
      lt.sort_column.should eq 0
      lt.sort_descending?.should be_false

      # A plain re-ingest of the same rows (e.g. a Resize re-ingest) stays sorted.
      lt.rows = lt.rows.dup
      body_column(lt, 0).should eq ["Alice", "Bob", "Charlie"]
    end
  end

  # Fix #2: on a same-count re-ingest, selection is restored by numeric index,
  # so it never lands on the header spacer (row 0 == "") or a wrong duplicate.
  describe "selection restore on same-count re-ingest" do
    it "restores selection to the same numeric row (not the header spacer)" do
      s = bugs3_screen
      lt = Crysterm::Widget::ListTable.new(
        parent: s,
        rows: [
          ["Name", "Note"],
          ["Alice", ""],
          ["Bob", ""],
          ["Carol", ""],
        ])

      # Select the second body row (item index 2 = "Bob").
      lt.current_index = 2
      lt.current_index.should eq 2
      lt.current_text.should contain("Bob")

      # Re-ingest with the same row count. The empty "Note" cells make a
      # value-lookup ambiguous, but an index restore keeps us on the same row.
      lt.rows = ([
        ["Name", "Note"],
        ["Alice", ""],
        ["Bob", ""],
        ["Carol", ""],
      ])

      # Must not fall back to the header spacer at index 0.
      lt.current_index.should_not eq 0
      lt.current_index.should eq 2
      lt.current_text.should contain("Bob")
    end

    it "does not land on a wrong duplicate row on same-count re-ingest" do
      s = bugs3_screen
      lt = Crysterm::Widget::ListTable.new(
        parent: s,
        rows: [
          ["Name", "Tag"],
          ["Dup", "x"],
          ["Mid", "y"],
          ["Dup", "z"],
        ])

      # Select the *second* "Dup" (item index 3). A value-based restore keys on
      # the row text and could resolve to the first "Dup" instead.
      lt.current_index = 3
      lt.current_index.should eq 3

      lt.rows = ([
        ["Name", "Tag"],
        ["Dup", "x"],
        ["Mid", "y"],
        ["Dup", "z"],
      ])

      lt.current_index.should eq 3
    end
  end

  # Fix #3: sorting a table with at most two rows (header + <=1 body) must not
  # crash and must record the sort state harmlessly.
  describe "sort on a small (<=2 row) table" do
    it "does not crash with a header and a single body row" do
      s = bugs3_screen
      lt = Crysterm::Widget::ListTable.new(
        parent: s,
        rows: [
          ["Name", "Score"],
          ["Only", "1"],
        ])

      lt.sort_by_column 0
      lt.sort_column.should eq 0
      body_column(lt, 0).should eq ["Only"]

      # A later ingest still does not crash and keeps the sort state.
      lt.rows = ([
        ["Name", "Score"],
        ["Solo", "2"],
      ])
      lt.sort_column.should eq 0
      body_column(lt, 0).should eq ["Solo"]
    end

    it "does not crash with a header-only table" do
      s = bugs3_screen
      lt = Crysterm::Widget::ListTable.new(
        parent: s,
        rows: [
          ["Name", "Score"],
        ])

      lt.sort_by_column 0
      lt.sort_column.should eq 0
      lt.rows.size.should eq 1
    end
  end
end

# W2 (OPT.md): `render_style_for` located each row's even/odd parity with
# `@items.index item` — O(n) per item per frame, so with `alternate_rows: true`
# O(n²) per frame. It now uses the mixin's O(1) identity map (`item_index_of`).
# The map returns nil for a non-item child (the pinned header, a scroll bar),
# exactly like `@items.index`, so those never pick up the alternate style —
# unlike an `item.top`-as-index shortcut, whose header `top` tracks the scroll
# offset (`@child_base`) and would misread an even offset as an even data row.
describe "ListTable alternate_rows parity after scroll (OPT W2)" do
  # Even body rows (index > 0, even) get `alternate_row`'s background; odd rows,
  # the header spacer (index 0), and the pinned header do not — and this holds
  # after a vertical scroll moves `@child_base`/`header.top`.
  it "styles even body rows and never the header, before and after scroll" do
    s = bugs3_screen
    lt = Crysterm::Widget::ListTable.new(
      parent: s,
      alternate_rows: true,
      rows: [
        ["Name", "Score"],
        ["r1", "1"], ["r2", "2"], ["r3", "3"], ["r4", "4"],
        ["r5", "5"], ["r6", "6"], ["r7", "7"], ["r8", "8"],
      ])
    lt.style.alternate_background_color = "#0000ff"
    alt_bg = lt.style.alternate_row.bg
    alt_bg.should_not be_nil

    # Oracle: exactly the parity the old `@items.index item` scan decided.
    verify = ->(label : String) do
      lt.item_boxes.each_with_index do |item, i|
        want_alt = i > 0 && i.even?
        got_alt = lt.render_style_for(item).bg == alt_bg
        got_alt.should eq(want_alt), "#{label}: item #{i}"
      end
      # The pinned header is a child too (`render_style_for` runs for every
      # child) but is not an `@items` member — it must never alternate.
      (lt.render_style_for(lt.header).bg == alt_bg).should be_false
    end

    verify.call "before scroll"

    # Simulate a vertical scroll: `@child_base` advances and `header.top` tracks
    # it (the exact even value an `item.top` shortcut would misread as a row).
    lt.child_base = 2
    lt.header.top = 2
    verify.call "child_base=2 header.top=2 (even)"

    lt.child_base = 3
    lt.header.top = 3
    verify.call "child_base=3 header.top=3"
  end
end

# W10 (OPT.md): the `Resize` handler ran a full `set_data @rows` on every event
# — costly during an interactive resize drag. A content-sized table's columns
# are content-driven and don't change with the parent, so the rebuild is now
# skipped for it; a fixed/percent-width table (whose columns track the parent)
# still rebuilds. Counting subclass makes the skip/rebuild directly observable.
private class CountingListTable < Crysterm::Widget::ListTable
  # Counts full data rebuilds. `#rows=` is the rebuild entry point: the former
  # `#set_data`/`#set_rows` pair was folded into this real setter, so counting
  # `#set_data` here silently counted a method nobody calls any more.
  property rebuild_calls = 0

  def rows=(rows)
    @rebuild_calls += 1
    super
  end
end

describe "ListTable Resize rebuild skip (OPT W10)" do
  it "skips the rows= rebuild on Resize when content-sized" do
    s = bugs3_screen
    lt = CountingListTable.new(parent: s, rows: [["A", "B"], ["1", "2"], ["3", "4"]])
    lt.rebuild_calls = 0
    lt.emit Crysterm::Event::Resize.new
    lt.rebuild_calls.should eq 0
  end

  it "still rebuilds on Resize for a percent-width table" do
    s = bugs3_screen
    lt = CountingListTable.new(parent: s, width: "50%", rows: [["A", "B"], ["1", "2"], ["3", "4"]])
    lt.rebuild_calls = 0
    lt.emit Crysterm::Event::Resize.new
    lt.rebuild_calls.should eq 1
  end
end
