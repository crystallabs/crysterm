require "./spec_helper"

include Crysterm

# Tables through the tag-markup round-trip (`TextTags`): the `tbl-N` /
# `tal-<spec>` block props must restore one shared `TextTableFormat`
# instance per table, so the markdown exporter groups the rows again.

private def round_trip(md : String) : {Crysterm::TextDocument, String, Crysterm::TextDocument}
  doc = Crysterm::TextDocument.from_markdown(md)
  tags = doc.tags
  back = Crysterm::TextDocument.new
  back.tags = tags
  {doc, tags, back}
end

private def table_formats(doc : Crysterm::TextDocument) : Array(Crysterm::TextTableFormat)
  doc.blocks.compact_map(&.block_format.table_format)
end

describe Crysterm::TextTags do
  describe "table props" do
    it "round-trips a plain GFM table as one shared table format" do
      doc, tags, back = round_trip "| a | b |\n|---|---|\n| 1 | 2 |\n"
      tags.should contain "tbl-2"
      back.to_markdown.should eq doc.to_markdown

      tfs = table_formats(back)
      tfs.size.should eq back.blocks.size
      tfs.all?(&.same?(tfs.first)).should be_true
      back.blocks.first.block_format.table_format.not_nil!.columns.should eq 2
    end

    it "round-trips column alignments" do
      doc, tags, back = round_trip "| a | b | c |\n|:---|:---:|---:|\n| 1 | 2 | 3 |\n"
      tags.should contain "tal-lcr"
      back.to_markdown.should eq doc.to_markdown
      back.blocks.first.block_format.table_format.not_nil!.alignments.should eq [
        Tput::AlignFlag::Left, Tput::AlignFlag::HCenter, Tput::AlignFlag::Right,
      ]
    end

    it "keeps two tables separated by a paragraph as distinct instances" do
      md = "| a | b |\n|---|---|\n| 1 | 2 |\n\npara\n\n| c | d |\n|---|---|\n| 3 | 4 |\n"
      doc, _tags, back = round_trip md
      back.to_markdown.should eq doc.to_markdown

      tfs = table_formats(back)
      distinct = [] of Crysterm::TextTableFormat
      tfs.each { |tf| distinct << tf unless distinct.any?(&.same?(tf)) }
      distinct.size.should eq 2
      back.blocks.any? { |b| b.block_format.table_format.nil? }.should be_true
    end

    it "drops a malformed tbl- prop" do
      doc = Crysterm::TextDocument.from_tags "{!block;tbl-x}row\n{!block;tbl-0}zero\n{!block;tal-lc}aligned only"
      doc.blocks.map(&.block_format.table_format).should eq [nil, nil, nil]
      doc.to_plain_text.should eq "row\nzero\naligned only"
    end
  end
end
