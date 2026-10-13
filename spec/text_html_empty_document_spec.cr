require "./spec_helper"

# An empty document exports as no HTML at all — what a Markdown renderer
# gives for an empty file — rather than a lone `<br>`, which a browser shows
# as a blank line; the importer reads "" back as the same empty document.
describe "TextHtml empty document export" do
  it "writes nothing for an empty document" do
    Crysterm::TextDocument.from_markdown("").to_html.should eq ""
    Crysterm::TextDocument.new.to_html.should eq ""
  end

  it "reads the empty export back as an empty document" do
    back = Crysterm::TextDocument.from_html(Crysterm::TextDocument.new.to_html)
    back.empty?.should be_true
    back.blocks.size.should eq 1
  end

  it "still writes an empty line between others" do
    Crysterm::TextDocument.new("a\n\nb").to_html.should contain "<br>"
  end
end
