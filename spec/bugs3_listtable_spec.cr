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
      lt.set_rows([
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

      lt.sort_by_column 0, descending: true
      body_column(lt, 0).should eq ["Charlie", "Bob", "Alice"]

      lt.set_rows([
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

      lt.set_rows([
        ["Name", "Score"],
        ["X", "100"],
        ["Y", "9"],
        ["Z", "20"],
      ])
      body_column(lt, 1).should eq ["9", "20", "100"]
    end

    it "records sort state so re-ingest via set_data keeps sorting" do
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
      lt.set_data lt.rows.dup
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
      lt.selekt 2
      lt.selected.should eq 2
      lt.value.should contain("Bob")

      # Re-ingest with the same row count. The empty "Note" cells make a
      # value-lookup ambiguous, but an index restore keeps us on the same row.
      lt.set_data([
        ["Name", "Note"],
        ["Alice", ""],
        ["Bob", ""],
        ["Carol", ""],
      ])

      # Must not fall back to the header spacer at index 0.
      lt.selected.should_not eq 0
      lt.selected.should eq 2
      lt.value.should contain("Bob")
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
      lt.selekt 3
      lt.selected.should eq 3

      lt.set_data([
        ["Name", "Tag"],
        ["Dup", "x"],
        ["Mid", "y"],
        ["Dup", "z"],
      ])

      lt.selected.should eq 3
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
      lt.set_rows([
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
