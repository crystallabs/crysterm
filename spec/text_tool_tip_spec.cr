require "./spec_helper"

# Link and image titles are kept as the text's tool tip
# (`TextCharFormat#tool_tip`, Qt's `QTextCharFormat::toolTip`), from the
# Markdown importer (`[x](u "T")`, `![a](s "T")`) and the HTML importer (any
# element's `title`), and written back by both exporters.
private def fragment_with(doc : Crysterm::TextDocument, text : String) : Crysterm::TextFragment
  doc.blocks.each do |b|
    b.fragments.each { |f| return f if f.text.includes?(text) }
  end
  raise "no fragment holding #{text.inspect}"
end

describe "TextCharFormat#tool_tip" do
  it "takes part in merge, equality and appearance" do
    a = Crysterm::TextCharFormat.new(bold: true)
    b = a.merge(Crysterm::TextCharFormat.new(tool_tip: "T"))
    b.tool_tip.should eq "T"
    b.bold?.should be_true
    b.merge(Crysterm::TextCharFormat.new(italic: true)).tool_tip.should eq "T"
    b.same_appearance?(a).should be_false
    b.should_not eq a
    Crysterm::TextCharFormat.new(tool_tip: "T").should eq Crysterm::TextCharFormat.new(tool_tip: "T")
  end

  it "keeps a Markdown link's title" do
    doc = Crysterm::TextDocument.from_markdown(%(see [here](https://x.io "The X") now))
    f = fragment_with(doc, "here")
    f.format.anchor_href.should eq "https://x.io"
    f.format.tool_tip.should eq "The X"
    fragment_with(doc, "now").format.tool_tip.should be_nil
  end

  it "keeps an inline image's title on its stand-in" do
    doc = Crysterm::TextDocument.from_markdown(%(a ![cat](c.png "A cat") b))
    f = fragment_with(doc, "cat")
    f.format.dim?.should be_true
    f.format.tool_tip.should eq "A cat"
  end

  it "keeps a block image's title on the image and its text" do
    doc = Crysterm::TextDocument.from_markdown(%(![cat](c.png "A cat")))
    doc.blocks[0].block_format.image.not_nil!.title.should eq "A cat"
    fragment_with(doc, "cat").format.tool_tip.should eq "A cat"
  end

  it "writes a link's title back to Markdown" do
    src = %(see [here](https://x.io "The \\"X\\"") now)
    written = Crysterm::TextDocument.from_markdown(src).to_markdown
    written.should contain %([here](https://x.io "The \\"X\\""))
    back = Crysterm::TextDocument.from_markdown(written)
    fragment_with(back, "here").format.tool_tip.should eq %(The "X")
  end

  it "escapes a backslash in a title" do
    doc = Crysterm::TextDocument.new
    Crysterm::TextCursor.new(doc).insert_text("x", Crysterm::TextCharFormat.new(anchor_href: "u", tool_tip: %(a\\*b)))
    written = doc.to_markdown
    Crysterm::TextDocument.from_markdown(written).blocks[0].fragments[0].format.tool_tip.should eq %(a\\*b)
  end

  it "writes a linked block image's link title back when the image has none" do
    src = %([![cat](c.png)](https://x.io "Home"))
    Crysterm::TextDocument.from_markdown(src).to_markdown.strip.should eq src
    html = Crysterm::TextDocument.from_markdown(src).to_html
    html.should contain %(<a href="https://x.io" title="Home"><img)
  end

  it "reads an HTML title attribute as the tool tip" do
    doc = Crysterm::TextDocument.from_html(%(<p><a href="u" title="L">link</a> <abbr title="Hypertext">HTML</abbr> <img src="c.png" alt="cat" title="A cat"> x</p>))
    fragment_with(doc, "link").format.tool_tip.should eq "L"
    fragment_with(doc, "HTML").format.tool_tip.should eq "Hypertext"
    fragment_with(doc, "cat").format.tool_tip.should eq "A cat"
    fragment_with(doc, " x").format.tool_tip.should be_nil
  end

  it "writes the tool tip back to HTML as Qt does" do
    doc = Crysterm::TextDocument.from_markdown(%(see [here](https://x.io "The X") and ![cat](c.png "A cat") now))
    html = doc.to_html
    html.should contain %(<a href="https://x.io" title="The X">here</a>)
    html.should contain %(<span title="A cat">)
    back = Crysterm::TextDocument.from_html(html)
    fragment_with(back, "here").format.tool_tip.should eq "The X"
    fragment_with(back, "cat").format.tool_tip.should eq "A cat"
  end
end
