require "./spec_helper"

include Crysterm

# HTML-subset interchange (`TextHtml`, TEXTEDIT.md Phase 3). Pure model.

private def html_doc(html : String) : Crysterm::TextDocument
  Crysterm::TextDocument.from_html(html)
end

describe Crysterm::TextHtml do
  describe ".parse" do
    it "imports paragraphs as adjacent blocks (explicit spacing only)" do
      doc = html_doc "<p>one</p><p>two</p><p></p><p>three</p>"
      doc.to_plain_text.should eq "one\ntwo\n\nthree"
    end

    it "imports inline formatting elements" do
      doc = html_doc "<p><b>b</b><i>i</i><u>u</u><s>s</s><code>c</code></p>"
      f = doc.blocks[0].fragments
      f[0].format.bold?.should be_true
      f[1].format.italic?.should be_true
      f[2].format.underline?.should be_true
      f[3].format.strike?.should be_true
      f[4].format.code?.should be_true
    end

    it "imports strong/em/ins/del/strike aliases and nesting" do
      doc = html_doc "<p><strong>x<em>y</em></strong><del>z</del></p>"
      f = doc.blocks[0].fragments
      f[0].format.bold?.should be_true
      f[1].format.bold?.should be_true
      f[1].format.italic?.should be_true
      f[2].format.strike?.should be_true
    end

    it "imports headings with level" do
      doc = html_doc "<h3>deep</h3>"
      doc.blocks[0].block_format.heading_level.should eq 3
      doc.blocks[0].text.should eq "deep"
    end

    it "imports anchors" do
      doc = html_doc %(<p><a href="https://example.com">go</a></p>)
      doc.blocks[0].fragments[0].format.anchor_href.should eq "https://example.com"
    end

    it "imports span styles and font color" do
      doc = html_doc %(<p><span style="color:#ff0000;background-color:#00ff00;font-weight:bold">x</span><font color="#0000ff">y</font></p>)
      f = doc.blocks[0].fragments
      f[0].format.fg.should eq 0xFF0000
      f[0].format.bg.should eq 0x00FF00
      f[0].format.bold?.should be_true
      f[1].format.fg.should eq 0x0000FF
    end

    it "imports text-decoration styles" do
      doc = html_doc %(<p><span style="text-decoration: underline line-through">x</span></p>)
      f = doc.blocks[0].fragments[0].format
      f.underline?.should be_true
      f.strike?.should be_true
    end

    it "imports block alignment and background" do
      doc = html_doc %(<p style="text-align:center;background-color:#112233">mid</p><p align="right">r</p>)
      doc.blocks[0].block_format.alignment.should eq Tput::AlignFlag::HCenter
      doc.blocks[0].block_format.bg.should eq 0x112233
      doc.blocks[1].block_format.alignment.should eq Tput::AlignFlag::Right
    end

    it "collapses whitespace outside pre" do
      html_doc("<p>a\n   b</p>\n<p>c</p>").to_plain_text.should eq "a b\nc"
    end

    it "imports br as a block break and hr as a rule" do
      doc = html_doc "<p>a<br>b</p><hr>"
      doc.blocks[0].text.should eq "a"
      doc.blocks[1].text.should eq "b"
      doc.blocks[2].text.should eq TextMarkdown.rule_text
    end

    it "imports pre as code-bg blocks preserving whitespace" do
      doc = html_doc "<pre>def x\n  y = 1</pre>"
      doc.blocks[0].text.should eq "def x"
      doc.blocks[1].text.should eq "  y = 1"
      doc.blocks[0].block_format.bg.should eq TextTheme.default.code_bg
      doc.blocks[0].fragments[0].format.code?.should be_true
    end

    it "imports lists as marker prefixes" do
      doc = html_doc "<ul><li>one</li><li>two</li></ul><ol><li>first</li></ol>"
      doc.blocks[0].text.should eq "• one"
      doc.blocks[1].text.should eq "• two"
      doc.blocks[2].text.should eq "1. first"
    end

    it "imports blockquotes with the quote prefix" do
      doc = html_doc "<blockquote><p>wise</p></blockquote>"
      doc.blocks[0].text.should eq "#{TextMarkdown.quote_prefix}wise"
    end

    it "skips script/style/head and walks unknown elements transparently" do
      doc = html_doc "<head><title>t</title></head><body><script>bad()</script><section><p>ok</p></section></body>"
      doc.to_plain_text.should eq "ok"
    end

    it "unescapes entities" do
      html_doc("<p>a &amp; b &lt;c&gt;</p>").to_plain_text.should eq "a & b <c>"
    end
  end

  describe ".generate" do
    it "round-trips text, formats and block properties" do
      doc = TextDocument.new("hello world\nsecond")
      doc.apply_char_format(0, 5, TextCharFormat.new(bold: true, fg: 0xFF0000))
      doc.apply_char_format(6, 11, TextCharFormat.new(italic: true, underline: true))
      # Explicit color: an *unstyled* anchor adopts the theme link color on
      # import (deliberate theming, same as markdown import).
      doc.apply_char_format(12, 18, TextCharFormat.new(anchor_href: "https://x.io", fg: 0x123456))
      doc.apply_block_format(0, 0, TextBlockFormat.new(alignment: Tput::AlignFlag::HCenter, bg: 0x334455))

      doc2 = TextDocument.from_html(doc.to_html)
      doc2.to_plain_text.should eq doc.to_plain_text
      doc2.char_format_runs(0, doc2.size).size.should eq doc.char_format_runs(0, doc.size).size
      doc.char_format_runs(0, doc.size).zip(doc2.char_format_runs(0, doc2.size)) do |(s1, e1, f1), (s2, e2, f2)|
        s2.should eq s1
        e2.should eq e1
        f2.fg.should eq f1.fg
        f2.attributes.should eq f1.attributes
        f2.anchor_href.should eq f1.anchor_href
      end
      doc2.blocks[0].block_format.alignment.should eq Tput::AlignFlag::HCenter
      doc2.blocks[0].block_format.bg.should eq 0x334455
    end

    it "escapes html specials" do
      doc = TextDocument.new("a < b & c > d")
      doc.to_html.should contain "&lt;"
      TextDocument.from_html(doc.to_html).to_plain_text.should eq "a < b & c > d"
    end

    it "preserves significant whitespace via white-space:pre-wrap" do
      doc = TextDocument.new("  indented list line")
      TextDocument.from_html(doc.to_html).to_plain_text.should eq "  indented list line"
    end

    it "round-trips empty separator blocks" do
      doc = TextDocument.new("a\n\nb")
      TextDocument.from_html(doc.to_html).to_plain_text.should eq "a\n\nb"
    end

    it "cross-converts a markdown import to html and back" do
      doc = TextDocument.from_markdown("# T\n\npara **bold** `code`\n\n- item")
      doc2 = TextDocument.from_html(doc.to_html)
      doc2.to_plain_text.should eq doc.to_plain_text
      doc2.blocks[0].block_format.heading_level.should eq 1
      # And the code flag survived, so markdown export still fences/backticks.
      doc2.to_markdown.should eq doc.to_markdown
    end
  end
end
