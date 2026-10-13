require "./spec_helper"

# Quotes in the HTML export. The Markdown importer keeps the `>` line
# between two paragraphs of a quote as an empty block of the quote's level
# (it shows the quote's bar), and a blank line between two quotes as a top
# margin on the second's first block, so `> a\n\n> b` and `> a\n>\n> b`
# differ only in that margin. cmark-gfm and md4c render the first as two
# `<blockquote>`s and the second as one holding two `<p>`s; the export does
# the same, and the importer reads either back to the same blocks.
describe "TextHtml quote export" do
  it "writes two quotes a blank line apart as two blockquotes" do
    doc = Crysterm::TextDocument.from_markdown("> a\n\n> b\n")
    doc.to_html.should eq "<blockquote><p>a</p></blockquote><blockquote>\n<p>b</p></blockquote>"
  end

  it "writes a quote's paragraphs as paragraphs, not as lines of one" do
    doc = Crysterm::TextDocument.from_markdown("> a\n>\n> b\n")
    doc.to_html.should eq "<blockquote><p>a</p>\n<p>b</p></blockquote>"
    doc = Crysterm::TextDocument.from_markdown("> # H\n> b\n>\n> ```\n> x\n> ```\n")
    doc.to_html.should eq "<blockquote><h1>H</h1>\n<p>b</p>\n<pre><code>x</code></pre></blockquote>"
  end

  it "keeps a quote's hard-broken lines in one paragraph" do
    Crysterm::TextDocument.from_markdown("> a\\\n> b\n").to_html.should eq "<blockquote><p>a<br>b</p></blockquote>"
  end

  it "ends every level of nested quotes at a blank line" do
    doc = Crysterm::TextDocument.from_markdown("> a\n> > b\n\n> > c\n")
    doc.to_html.should eq "<blockquote><p>a</p><blockquote>\n<p>b</p></blockquote></blockquote>" \
                          "<blockquote><blockquote>\n<p>c</p></blockquote></blockquote>"
  end

  it "keeps a margin that is not between two quotes" do
    doc = Crysterm::TextDocument.from_markdown("> a\n\n---\n\n> b\n")
    doc.to_html.should eq %(<blockquote><p>a</p></blockquote>\n<hr style="margin-top:1em">) +
                          %(<blockquote>\n<p style="margin-top:1em">b</p></blockquote>)
  end

  it "reads back the blocks the Markdown importer makes" do
    ["> a\n\n> b\n", "> a\n>\n> b\n", "> a\n> > b\n\n> > c\n", "> a\n>\n> > b\n>\n> c\n",
     "> a\n>\n> ```\n> x\n> ```\n>\n> b\n", "> - a\n>\n> b\n", "> a\n\n---\n\n> b\n", "> a\n\n\n> b\n"].each do |md|
      doc = Crysterm::TextDocument.from_markdown(md)
      back = Crysterm::TextDocument.from_html(doc.to_html)
      shape = ->(d : Crysterm::TextDocument) {
        d.blocks.map { |b| {b.text, b.block_format.quote_level, b.block_format.top_margin, b.block_format.list_format.nil?} }
      }
      shape.call(back).should eq shape.call(doc)
      back.to_html.should eq doc.to_html
    end
  end

  it "imports cmark-gfm's quotes as the Markdown importer does" do
    {
      "> a\n\n> b\n"    => "<blockquote>\n<p>a</p>\n</blockquote>\n<blockquote>\n<p>b</p>\n</blockquote>\n",
      "> a\n>\n> b\n"   => "<blockquote>\n<p>a</p>\n<p>b</p>\n</blockquote>\n",
      "> a\n>\n> > b\n" => "<blockquote>\n<p>a</p>\n<blockquote>\n<p>b</p>\n</blockquote>\n</blockquote>\n",
    }.each do |md, html|
      from_html = Crysterm::TextDocument.from_html(html)
      from_md = Crysterm::TextDocument.from_markdown(md)
      from_html.blocks.map { |b| {b.text, b.block_format.quote_level, b.block_format.top_margin} }
        .should eq from_md.blocks.map { |b| {b.text, b.block_format.quote_level, b.block_format.top_margin} }
    end
  end
end
