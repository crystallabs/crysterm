require "./spec_helper"

# GFM alerts in HTML: the export writes an alert's quote in the form
# github.com renders it — a `markdown-alert` `<div>` whose first child is
# the `markdown-alert-title` paragraph (GitHub's octicon left out) — and the
# importer reads that form, GitHub's own markup included, back to the alert.
describe "TextHtml GFM alerts" do
  it "writes each kind as GitHub's alert markup" do
    Crysterm::TextBlockFormat::AlertKind.each do |kind|
      doc = Crysterm::TextDocument.from_markdown("> [!#{kind.to_s.upcase}]\n> text\n")
      doc.to_html.should eq %(<div class="markdown-alert markdown-alert-#{kind.to_s.downcase}">) +
                            %(<p class="markdown-alert-title">#{kind}</p><p>text</p></div>)
    end
  end

  it "writes an alert's paragraphs and a quote nested in it inside its div" do
    doc = Crysterm::TextDocument.from_markdown("> [!NOTE]\n> a\n>\n> b\n>\n> > inner\n")
    doc.to_html.should eq %(<div class="markdown-alert markdown-alert-note"><p class="markdown-alert-title">Note</p>) +
                          %(<p>a</p>\n<p>b</p><blockquote>\n<p>inner</p></blockquote></div>)
  end

  it "writes two alerts a blank line apart as two divs" do
    doc = Crysterm::TextDocument.from_markdown("> [!NOTE]\n> a\n\n> [!NOTE]\n> b\n\n> [!TIP]\n> c\n\n> q\n")
    doc.to_html.should eq %(<div class="markdown-alert markdown-alert-note"><p class="markdown-alert-title">Note</p><p>a</p></div>) +
                          %(<div class="markdown-alert markdown-alert-note"><p class="markdown-alert-title">Note</p>\n<p>b</p></div>) +
                          %(<div class="markdown-alert markdown-alert-tip"><p class="markdown-alert-title">Tip</p>\n<p>c</p></div>) +
                          %(<blockquote>\n<p>q</p></blockquote>)
  end

  it "writes an alert nested in an alert as a div in the div" do
    doc = Crysterm::TextDocument.from_markdown("> [!NOTE]\n> a\n>\n> > [!TIP]\n> > b\n>\n> c\n")
    doc.to_html.should eq %(<div class="markdown-alert markdown-alert-note"><p class="markdown-alert-title">Note</p><p>a</p>) +
                          %(<div class="markdown-alert markdown-alert-tip"><p class="markdown-alert-title">Tip</p>\n<p>b</p></div>\n<p>c</p></div>)
  end

  it "reads its export back to the same alerts" do
    ["> [!NOTE]\n> a\n", "> [!NOTE]\n> a\n>\n> b\n", "> [!NOTE]\n> a\n\n> [!TIP]\n> b\n",
     "> [!NOTE]\n> a\n\n> [!NOTE]\n> b\n", "> [!NOTE]\n> a\n>\n> > inner\n",
     "> [!NOTE]\n> a\n>\n> > [!TIP]\n> > b\n>\n> c\n", "> [!CAUTION]\n",
     "> [!WARNING]\n> - a\n> - b\n>\n> | x | y |\n> |---|---|\n> | 1 | 2 |\n", "> q\n\n> [!IMPORTANT]\n> **b**\n"].each do |md|
      doc = Crysterm::TextDocument.from_markdown(md)
      back = Crysterm::TextDocument.from_html(doc.to_html)
      shape = ->(d : Crysterm::TextDocument) {
        d.blocks.map { |b| {b.text, b.block_format.quote_level, b.block_format.alert_kind, b.block_format.top_margin} }
      }
      shape.call(back).should eq shape.call(doc)
      back.to_markdown.should eq doc.to_markdown
    end
  end

  it "imports GitHub's rendering of an alert" do
    html = %(<div class="markdown-alert markdown-alert-tip" dir="auto"><p class="markdown-alert-title" dir="auto">) +
           %(<svg class="octicon octicon-light-bulb mr-2" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">) +
           %(<path d="M8 1.5c-2.363 0-4 1.69-4 3.75"></path></svg>Tip</p><p dir="auto">a</p>\n<p dir="auto">b</p>\n</div>\n)
    doc = Crysterm::TextDocument.from_html(html)
    doc.blocks.map(&.text).should eq ["a", "", "b"]
    doc.blocks.each do |b|
      b.block_format.quote_level.should eq 1
      b.block_format.alert_kind.should eq Crysterm::TextBlockFormat::AlertKind::Tip
    end
    doc.to_markdown.should eq "> [!TIP]\n> a\n>\n> b"
  end

  it "leaves a div of no alert kind a plain block" do
    doc = Crysterm::TextDocument.from_html(%(<div class="markdown-alert markdown-alert-bogus"><p>x</p></div>))
    doc.blocks[0].block_format.quote_level.should eq 0
    doc.blocks[0].block_format.alert_kind.should be_nil
  end
end
