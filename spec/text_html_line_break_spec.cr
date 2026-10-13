require "./spec_helper"

# A hard line break — Markdown's two trailing spaces or `\` at a line's end —
# starts a block of its own in the model, with no margin above it. The HTML
# export writes such lines as one element with `<br>` between them (as Qt's
# `toHtml` writes its line separator), so a browser shows one paragraph, as
# the viewer does, rather than paragraphs a margin apart; the importer splits
# `<br>` back into the same blocks.
describe "TextHtml hard line break export" do
  it "writes a hard-broken paragraph as one p" do
    doc = Crysterm::TextDocument.from_markdown("line one  \nline two\\\nline three\n\nnext\n")
    doc.to_html.should eq %(<p>line one<br>line two<br>line three</p>\n<p style="margin-top:1em">next</p>)
  end

  it "keeps a setext heading's lines in one heading" do
    doc = Crysterm::TextDocument.from_markdown("a\\\nb\n---\n")
    doc.to_html.should eq "<h2>a<br>b</h2>"
  end

  it "keeps a list item's broken lines in its li" do
    doc = Crysterm::TextDocument.from_markdown("- a  \n  b\n- c\n")
    doc.to_html.should eq "<ul><li>a<br>b</li>\n<li>c</li></ul>"
  end

  it "keeps a quote's broken lines in one p" do
    doc = Crysterm::TextDocument.from_markdown("> a  \n> b\n")
    doc.to_html.should eq "<blockquote><p>a<br>b</p></blockquote>"
  end

  it "takes the last line's bottom margin and keeps its spaces" do
    blocks = [
      Crysterm::TextBlock.new("a", block_format: Crysterm::TextBlockFormat.new(top_margin: 2)),
      Crysterm::TextBlock.new(" b", block_format: Crysterm::TextBlockFormat.new(bottom_margin: 1)),
    ]
    html = Crysterm::TextHtml.generate(blocks)
    html.should eq %(<p style="margin-top:2em;margin-bottom:1em;white-space:pre-wrap">a<br> b</p>)
    back = Crysterm::TextHtml.parse(html)
    back.map(&.text).should eq ["a", " b"]
    back.map(&.block_format.top_margin).should eq [2, 0]
    back.map(&.block_format.bottom_margin).should eq [0, 1]
  end

  it "keeps paragraphs set apart by a margin, rules and code apart" do
    doc = Crysterm::TextDocument.from_markdown("a\n\nb\n\n---\n\n```\nc\n```\n")
    html = doc.to_html
    html.should_not contain "<br>"
    html.scan(/<p[ >]/).size.should eq 2
  end

  it "round-trips the lines through the importer" do
    src = "x  \ny\\\nz\n\n- a  \n  b\n\n> q  \n> r\n\nA\\\nB\n===\n"
    doc = Crysterm::TextDocument.from_markdown(src)
    back = Crysterm::TextDocument.from_html(doc.to_html)
    shape = ->(d : Crysterm::TextDocument) do
      d.blocks.map do |b|
        f = b.block_format
        {b.text, f.list_format.try(&.indent), f.indent, f.quote_level, f.heading_level, f.top_margin, f.bottom_margin}
      end
    end
    shape.call(back).should eq shape.call(doc)
  end
end
