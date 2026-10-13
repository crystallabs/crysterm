require "./spec_helper"

# A nested list exports inside the item it belongs to — `<li>a<ul>…</ul></li>`,
# as HTML nests lists — and so does an item's continuation content (a
# paragraph or code block at its content column), rather than a `<ul>`
# directly inside a `<ul>` (invalid HTML) or a paragraph after the list.
describe "TextHtml list nesting export" do
  it "writes a nested list inside its parent item" do
    doc = Crysterm::TextDocument.from_markdown("- a\n  - b\n    - c\n- d\n")
    doc.to_html.should eq "<ul><li>a<ul>\n<li>b<ul>\n<li>c</li></ul></li></ul></li>\n<li>d</li></ul>"
  end

  it "writes a nested ordered list inside its parent item" do
    doc = Crysterm::TextDocument.from_markdown("1. x\n   1. y\n2. z\n")
    doc.to_html.should eq "<ol><li>x<ol>\n<li>y</li></ol></li>\n<li>z</li></ol>"
  end

  it "writes an item's continuation paragraph and code inside its li" do
    doc = Crysterm::TextDocument.from_markdown("- a\n\n  para\n\n  ```\n  code\n  ```\n- b\n")
    html = doc.to_html
    html.should eq "<ul><li>a<br>para<pre><code>code</code></pre></li>\n<li>b</li></ul>"
    html.should_not contain "margin-left"
  end

  it "opens a bare li for an item that starts with a nested list" do
    doc = Crysterm::TextDocument.from_markdown("- - a\n")
    html = doc.to_html
    html.should eq "<ul><li><ul><li>a</li></ul></li></ul>"
  end

  it "round-trips the nesting through the importer" do
    src = "- a\n  - b\n\n    bpara\n  - c\n\n  apara\n- d\n\n1. x\n   1. y\n"
    doc = Crysterm::TextDocument.from_markdown(src)
    back = Crysterm::TextDocument.from_html(doc.to_html)
    shape = ->(d : Crysterm::TextDocument) do
      d.blocks.map { |b| {b.text, b.block_format.list_format.try(&.indent), b.block_format.indent} }
    end
    shape.call(back).should eq shape.call(doc)
    back.blocks[0].block_format.list_format.should be(back.blocks[5].block_format.list_format)
  end
end
