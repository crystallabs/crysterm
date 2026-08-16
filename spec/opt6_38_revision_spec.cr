require "./spec_helper"

include Crysterm

# O6-38 tier 2 + A4-49: `TextDocument#revision` (monotonic mutation
# counter, bumped at the single `finish_edit` choke point), the
# revision-keyed memo of `TextTable`'s grid scan, and the interchange
# getter aliases `markdown`/`html`/`tags`.

private GFM = "| Name | N |\n| --- | ---: |\n| ab | 1 |\n| c | 22 |"

private def table_doc
  doc = TextDocument.from_markdown(GFM)
  {doc, TextTable.new(doc, doc.blocks[0].block_format.table_format.not_nil!)}
end

# Exposes the private grid-scan memo so specs can assert reuse by object
# identity, and counts `member?` calls as a proxy for document scans.
private class ProbeTable < Crysterm::TextTable
  getter member_calls = 0

  def member?(block : Crysterm::TextBlock) : Bool
    @member_calls += 1
    super
  end

  def probe_data_rows
    data_row_indexed
  end
end

private def probe_table_doc
  doc = TextDocument.from_markdown(GFM)
  {doc, ProbeTable.new(doc, doc.blocks[0].block_format.table_format.not_nil!)}
end

describe Crysterm::TextDocument do
  describe "#revision" do
    it "bumps on set_plain_text (whole-content replace)" do
      doc = TextDocument.new("a\nb")
      r0 = doc.revision
      doc.set_plain_text("c\nd")
      doc.revision.should be > r0
    end

    it "bumps on cursor text insertion" do
      doc = TextDocument.new("hello")
      r0 = doc.revision
      c = TextCursor.new(doc, 5)
      c.insert_text(" world")
      doc.revision.should be > r0
    end

    it "bumps on a block format change" do
      doc = TextDocument.new("hello")
      r0 = doc.revision
      doc.cursor(0, 0).merge_block_format(TextBlockFormat.new(heading_level: 2))
      doc.revision.should be > r0
    end

    it "bumps on fragment insertion, removal and undo/redo replay" do
      doc = TextDocument.new("hello")
      r0 = doc.revision
      doc.cursor(5).insert_fragment(TextDocumentFragment.from_markdown("**b**"))
      r1 = doc.revision
      r1.should be > r0
      doc.cursor(0, 2).remove_selected_text
      r2 = doc.revision
      r2.should be > r1
      doc.undo.should be_true
      r3 = doc.revision
      r3.should be > r2
      doc.redo.should be_true
      doc.revision.should be > r3
    end

    it "bumps on a char format change" do
      doc = TextDocument.new("hello")
      r0 = doc.revision
      doc.cursor(0, 5).merge_char_format(TextCharFormat.new(bold: true))
      doc.revision.should be > r0
    end

    it "does not bump on pure reads" do
      doc, tbl = table_doc
      r0 = doc.revision
      doc.to_plain_text
      doc.to_markdown
      doc.to_html
      doc.to_tags
      doc.typing_format_at(3)
      doc.find("Name")
      range = tbl.cell_text_range(0, 0).not_nil!
      tbl.cell_at(range.begin)
      tbl.cell_text(1, 1)
      tbl.rows
      doc.revision.should eq r0
    end
  end

  describe "interchange getter aliases (A4-49)" do
    it "aliases the to_* exporters" do
      doc = TextDocument.from_markdown("# Title\n\nSome **bold** text.")
      doc.markdown.should eq doc.to_markdown
      doc.html.should eq doc.to_html
      doc.tags.should eq doc.to_tags
      doc.plain_text.should eq doc.to_plain_text
    end

    it "round-trips through the matching setters" do
      doc = TextDocument.from_markdown("Some **bold** text.")
      other = TextDocument.new
      other.markdown = doc.markdown
      other.to_markdown.should eq doc.to_markdown
      other.tags = doc.tags
      other.to_tags.should eq doc.to_tags
    end
  end
end

describe Crysterm::TextTable do
  describe "grid-scan memo (O6-38 tier 2)" do
    it "reuses one scan for repeated lookups within a revision" do
      _, tbl = probe_table_doc
      a = tbl.probe_data_rows
      b = tbl.probe_data_rows
      b.should be a
      # The memoized scan visited each block once; a memo hit re-visits none.
      scans = tbl.member_calls
      tbl.probe_data_rows
      tbl.member_calls.should eq scans
    end

    it "serves cell_at / cell_text_range / grid lookups from the memo" do
      doc, tbl = probe_table_doc
      range = tbl.cell_text_range(1, 0).not_nil!
      after_first = tbl.member_calls
      memo = tbl.probe_data_rows
      # Repeated per-keystroke lookups: only the O(1) membership test of the
      # positioned block runs again, never a full document scan.
      tbl.cell_at(range.begin).should eq({1, 0})
      tbl.cell_at(range.begin).should eq({1, 0})
      tbl.cell_text_range(1, 0).should eq range
      tbl.rows.should eq 3
      (tbl.member_calls - after_first).should be < doc.block_count
      tbl.probe_data_rows.should be memo
    end

    it "is invalidated by a table editing op" do
      doc, tbl = probe_table_doc
      memo = tbl.probe_data_rows
      r0 = doc.revision
      tbl.set_cell_text(1, 0, "abcdef").should be_true
      doc.revision.should be > r0
      tbl.probe_data_rows.should_not be memo
      tbl.cell_text(1, 0).should eq "abcdef"
      range = tbl.cell_text_range(1, 0).not_nil!
      doc.plain_text(range.begin, range.end).should eq "abcdef"
      tbl.cell_at(range.begin).should eq({1, 0})
    end

    it "is invalidated by an external document edit" do
      doc, tbl = probe_table_doc
      before = tbl.cell_text_range(0, 0).not_nil!
      memo = tbl.probe_data_rows
      # Prepend a paragraph before the table: block indexes and positions of
      # every data row shift.
      doc.cursor(0).insert_text("intro\n")
      tbl.probe_data_rows.should_not be memo
      range = tbl.cell_text_range(0, 0).not_nil!
      range.should_not eq before
      doc.plain_text(range.begin, range.end).should eq "Name"
      tbl.cell_at(range.begin).should eq({0, 0})
    end

    it "stays fresh across row restructuring" do
      _, tbl = probe_table_doc
      tbl.probe_data_rows
      tbl.insert_row(1, ["x", "9"]).should be_true
      tbl.rows.should eq 4
      tbl.cell_text(1, 0).should eq "x"
      tbl.remove_row(1).should be_true
      tbl.rows.should eq 3
      tbl.cell_text(1, 0).should eq "ab"
    end
  end
end
