require "./spec_helper"

# A fenced code block exports as one `<pre>`, its lines a line break apart,
# rather than a `<pre>` per line, which a browser sets apart by its default
# margins; the importer splits it back into the same lines.
describe "TextHtml code block export" do
  it "writes a fenced block's lines into one pre" do
    doc = Crysterm::TextDocument.from_markdown("Para\n\n```sh\necho a\n  echo b\n\necho c\n```\n\nAfter\n")
    html = doc.to_html
    html.scan("<pre").size.should eq 1
    html.should contain "echo a</code>\n<code>  echo b</code>\n\n<code>echo c"
    back = Crysterm::TextDocument.from_html(html)
    code = back.blocks.select(&.block_format.code_block?)
    code.map(&.text).should eq ["echo a", "  echo b", "", "echo c"]
    code.map(&.block_format.code_language).uniq!.should eq ["sh"]
  end

  it "keeps two fenced blocks apart by the margin between them" do
    doc = Crysterm::TextDocument.from_markdown("```\na\nb\n```\n\n```\nc\n```\n")
    html = doc.to_html
    html.scan("<pre").size.should eq 2
    Crysterm::TextDocument.from_html(html).blocks.map(&.text).should eq doc.blocks.map(&.text)
  end

  it "keeps a fenced block in a quote within the quote" do
    doc = Crysterm::TextDocument.from_markdown("> ```\n> x\n> y\n> ```\n")
    html = doc.to_html
    html.scan("<pre").size.should eq 1
    html.should start_with "<blockquote><pre"
    html.should end_with "</pre></blockquote>"
  end
end
