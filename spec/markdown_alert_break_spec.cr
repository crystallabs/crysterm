require "./spec_helper"

# Markdown export of GFM alerts next to quotes: the `[!KIND]` title line
# goes on the block that opens an alert — not on the quote's blank `>` line
# before a second quote, which a blank line sets apart from the first and
# which opens its own alert even of the same kind — and a quote nested in an
# alert, or the alert going on after one, takes none.
describe "TextMarkdown alert export" do
  {
    "two alerts a blank line apart"        => "> [!NOTE]\n> a\n>\n\n> [!TIP]\n> b",
    "two alerts of one kind"               => "> [!NOTE]\n> a\n>\n\n> [!NOTE]\n> b",
    "an alert after a quote"               => "> a\n>\n\n> [!NOTE]\n> b",
    "a quote nested in an alert"           => "> [!NOTE]\n> a\n>\n> > inner",
    "an alert going on after a nested one" => "> [!NOTE]\n> a\n>\n> > [!TIP]\n> > b\n>\n> c",
    "an alert of two paragraphs"           => "> [!NOTE]\n> a\n>\n> b",
  }.each do |what, md|
    it "writes #{what} as it reads it" do
      doc = Crysterm::TextDocument.from_markdown(md)
      doc.to_markdown.should eq md
      shape = ->(d : Crysterm::TextDocument) {
        d.blocks.map { |b| {b.text, b.block_format.quote_level, b.block_format.alert_kind, b.block_format.top_margin} }
      }
      shape.call(Crysterm::TextDocument.from_markdown(doc.to_markdown)).should eq shape.call(doc)
    end
  end
end
