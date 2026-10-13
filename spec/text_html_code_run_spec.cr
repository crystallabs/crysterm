require "./spec_helper"

# A fenced code block exports as one `<pre>`, its lines a line break apart,
# rather than a `<pre>` per line, which a browser sets apart by its default
# margins; the importer splits it back into the same lines.
describe "TextHtml code block export" do
  it "writes a fenced block's lines into one pre" do
    doc = Crysterm::TextDocument.from_markdown("Para\n\n```sh\necho a\n  echo b\n\necho c\n```\n\nAfter\n")
    html = doc.to_html
    html.scan("<pre").size.should eq 1
    html.should contain %(<pre style="margin-top:1em"><code class="language-sh">echo a\n  echo b\n\necho c</code></pre>)
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

  it "writes the lines in one code element carrying the language, as CommonMark renderers do" do
    doc = Crysterm::TextDocument.from_markdown("```ruby\ndef x\n  1 < 2\nend\n```\n")
    doc.to_html.should eq %(<pre><code class="language-ruby">def x\n  1 &lt; 2\nend</code></pre>)
    back = Crysterm::TextDocument.from_html(doc.to_html)
    back.blocks.map(&.text).should eq ["def x", "  1 < 2", "end"]
    back.blocks.map(&.block_format.code_language).uniq!.should eq ["ruby"]
    back.blocks.all?(&.fragments.all?(&.format.code?)).should be_true
  end
end
