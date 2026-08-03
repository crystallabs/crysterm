require "./spec_helper"

include Crysterm

# GFM alerts (https://github.github.com/gfm/, the github.com blockquote
# extension): a blockquote whose first line is `[!NOTE]`/`[!TIP]`/
# `[!IMPORTANT]`/`[!WARNING]`/`[!CAUTION]` renders as a styled admonition
# instead of a plain quote.
#
# Import strips the marker line (`TextBlockFormat#alert_kind` records the
# kind instead — the title chip is a render-time decoration, not document
# text); export re-emits the marker as the alert's first line, byte-stable
# and idempotent across a round-trip.
describe "GFM alerts" do
  describe "import" do
    it "flags a NOTE alert's blocks and drops the literal [!NOTE] marker text" do
      doc = TextDocument.from_markdown("> [!NOTE]\n> Highlights information that users should know.")
      doc.blocks[0].block_format.alert_kind.should eq TextBlockFormat::AlertKind::Note
      doc.blocks[0].block_format.quote_level.should eq 1
      doc.blocks[0].text.should eq "Highlights information that users should know."
      doc.blocks[0].text.should_not contain "[!NOTE]"
    end

    it "recognizes every alert kind" do
      {
        "TIP"       => TextBlockFormat::AlertKind::Tip,
        "IMPORTANT" => TextBlockFormat::AlertKind::Important,
        "WARNING"   => TextBlockFormat::AlertKind::Warning,
        "CAUTION"   => TextBlockFormat::AlertKind::Caution,
      }.each do |marker, kind|
        doc = TextDocument.from_markdown("> [!#{marker}]\n> body")
        doc.blocks[0].block_format.alert_kind.should eq kind
        doc.blocks[0].text.should eq "body"
      end
    end
  end

  describe "export" do
    it "round-trips a NOTE alert with two paragraphs byte-stable and idempotent" do
      md = "> [!NOTE]\n> Paragraph one.\n>\n> Paragraph two."
      doc = TextDocument.from_markdown(md)
      rendered = doc.to_markdown
      rendered.should eq md
      # Idempotent: re-importing the exported text reproduces the same block
      # structure (kind, quote level, and stripped text on every block).
      doc2 = TextDocument.from_markdown(rendered)
      doc2.to_markdown.should eq md
      doc2.block_count.should eq doc.block_count
      doc.blocks.each_with_index do |b, i|
        doc2.blocks[i].block_format.alert_kind.should eq b.block_format.alert_kind
        doc2.blocks[i].block_format.quote_level.should eq b.block_format.quote_level
        doc2.blocks[i].text.should eq b.text
      end
    end
  end

  describe "unaffected cases" do
    it "leaves a plain blockquote with no marker as an ordinary quote" do
      doc = TextDocument.from_markdown("> just a quote")
      doc.blocks[0].block_format.alert_kind.should be_nil
      doc.blocks[0].block_format.quote_level.should eq 1
      doc.blocks[0].text.should eq "just a quote"
    end

    it "leaves a lowercase [!note] marker as literal quote text (GFM requires uppercase)" do
      doc = TextDocument.from_markdown("> [!note]\n> body")
      doc.blocks[0].block_format.alert_kind.should be_nil
      doc.blocks[0].text.should eq "[!note] body"
    end

    it "leaves a backslash-escaped \\[!NOTE] marker as a plain quote" do
      doc = TextDocument.from_markdown("> \\[!NOTE]\n> body")
      doc.blocks[0].block_format.alert_kind.should be_nil
      doc.blocks[0].text.should eq "[!NOTE] body"
    end
  end
end
