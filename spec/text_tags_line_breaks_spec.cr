require "./spec_helper"

# Tag markup with CRLF or CR line breaks splits into the same blocks as with
# LF ones, as the plain-text and Markdown setters do
# (`TextDocument.normalize_line_breaks`): no block keeps a '\r'.
describe "TextTags line breaks" do
  it "takes CRLF and a lone CR as a line break" do
    doc = Crysterm::TextDocument.from_tags("a\r\n{bold}b{/bold}\rc\n\r\nd")
    doc.blocks.map(&.text).should eq ["a", "b", "c", "", "d"]
    doc.to_plain_text.should_not contain '\r'
    doc.blocks[1].fragments.first.format.bold?.should be_true
  end

  it "does the same for a fragment" do
    Crysterm::TextDocumentFragment.from_tags("x\r\ny").to_plain_text.should eq "x\ny"
  end

  it "leaves the HTML importer's line breaks as the HTML parser gives them" do
    Crysterm::TextDocument.from_html("<pre>a\r\nb\rc</pre>").blocks.map(&.text).should eq ["a", "b", "c"]
  end
end
