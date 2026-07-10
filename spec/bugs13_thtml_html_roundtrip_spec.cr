require "./spec_helper"

include Crysterm

# BUGS13 T8/T11/T14/T16/T22/T30/T31 — HTML importer/exporter round-trip
# fidelity and untrusted-input robustness (`TextHtml`). Pure model.

private def html_doc(html : String) : Crysterm::TextDocument
  Crysterm::TextDocument.from_html(html)
end

describe "BUGS13 T31 wrapper block elements import no phantom empty block" do
  it "imports <div><p>hello</p></div> as exactly one block" do
    doc = html_doc "<div><p>hello</p></div>"
    doc.blocks.size.should eq 1
    doc.blocks[0].text.should eq "hello"
  end

  it "imports nested wrappers without one phantom per level" do
    doc = html_doc "<div><div><p>a</p><p>b</p></div></div>"
    doc.to_plain_text.should eq "a\nb"
    doc.blocks.size.should eq 2
  end

  it "discards a wrapper's virgin block before a nested list" do
    doc = html_doc "<div><ul><li>x</li></ul></div>"
    doc.blocks.size.should eq 1
    doc.blocks[0].block_format.list_format.should_not be_nil
  end

  it "re-donates the wrapper's consumed margin to the real block" do
    doc = html_doc %(<p></p><div><p>x</p></div>)
    doc.blocks.size.should eq 1
    doc.blocks[0].block_format.top_margin.should eq 1
  end

  it "re-donates a wrapper's own margin-top style too" do
    doc = html_doc %(<div style="margin-top:2em"><p>x</p></div>)
    doc.blocks.size.should eq 1
    doc.blocks[0].block_format.top_margin.should eq 2
  end

  it "keeps wrapper text around nested blocks" do
    doc = html_doc "<div>lead<p>mid</p>tail</div>"
    doc.to_plain_text.should eq "lead\nmid\ntail"
  end
end

describe "BUGS13 T11 empty default blocks export as <br>, not <p></p>" do
  it "round-trips a\\n\\nb without folding the empty block into a margin" do
    doc = Crysterm::TextDocument.new("a\n\nb")
    html = doc.to_html
    html.should contain "<br>"
    back = html_doc(html)
    back.blocks.size.should eq 3
    back.to_plain_text.should eq "a\n\nb"
    # Stable across repeated round-trips.
    html_doc(back.to_html).to_plain_text.should eq "a\n\nb"
  end

  it "round-trips leading and trailing empty blocks" do
    doc = Crysterm::TextDocument.new("\nx\n")
    back = html_doc(doc.to_html)
    back.to_plain_text.should eq "\nx\n"
    back.blocks.size.should eq 3
  end

  it "keeps a styled empty block a real <p> block" do
    doc = Crysterm::TextDocument.new("a\n\nb")
    doc.blocks[1].block_format = TextBlockFormat.new(bg: 0x333333)
    back = html_doc(doc.to_html)
    back.blocks.size.should eq 3
    back.blocks[1].block_format.bg.should eq 0x333333
  end
end

describe "BUGS13 T8 empty <li> still emits its member block" do
  it "keeps an empty item in a plain list" do
    doc = html_doc "<ul><li>a</li><li></li><li>b</li></ul>"
    doc.blocks.size.should eq 3
    doc.blocks[1].text.should eq ""
    lf = doc.blocks[1].block_format.list_format
    lf.should_not be_nil
    lf.try(&.same?(doc.blocks[0].block_format.list_format)).should be_true
  end

  it "round-trips the exporter's own empty checkbox item" do
    doc = html_doc %(<ul><li><input type="checkbox" checked disabled>done</li><li><input type="checkbox" disabled></li></ul>)
    doc.blocks.size.should eq 2
    doc.blocks[1].text.should eq ""
    back = html_doc(doc.to_html)
    back.blocks.size.should eq 2
    back.blocks[0].block_format.checked?.should be_true
    back.blocks[1].block_format.checked?.should be_false
    back.blocks[1].block_format.list_format.try(&.style.checkbox?).should be_true
  end
end

describe "BUGS13 T14 table column alignments survive the HTML round-trip" do
  it "imports text-align cell styles and re-exports them" do
    doc = html_doc %(<table><tr><th style="text-align:right">h1</th><th style="text-align:center">h2</th></tr><tr><td>1</td><td>2</td></tr></table>)
    tf = doc.blocks[0].block_format.table_format
    tf.should_not be_nil
    als = tf.try(&.alignments)
    als.should_not be_nil
    als.try(&.[0].right?).should be_true
    als.try(&.[1].h_center?).should be_true

    exported = doc.to_html
    exported.should contain "text-align:right"
    exported.should contain "text-align:center"

    back = html_doc(exported)
    bals = back.blocks[0].block_format.table_format.try(&.alignments)
    bals.try(&.[0].right?).should be_true
    bals.try(&.[1].h_center?).should be_true
  end

  it "reads the legacy align attribute too" do
    doc = html_doc %(<table><tr><th align="right">h</th></tr><tr><td>1</td></tr></table>)
    doc.blocks[0].block_format.table_format.try(&.alignments).try(&.[0].right?).should be_true
  end

  it "keeps alignments nil when no cell declares one" do
    doc = html_doc "<table><tr><th>h</th></tr><tr><td>1</td></tr></table>"
    doc.blocks[0].block_format.table_format.try(&.alignments).should be_nil
  end
end

describe "BUGS13 T16 TAB characters survive the HTML round-trip" do
  it "marks tabbed text pre-wrap and reimports it verbatim" do
    doc = Crysterm::TextDocument.new("a\tb")
    exported = doc.to_html
    exported.should contain "white-space:pre-wrap"
    html_doc(exported).to_plain_text.should eq "a\tb"
  end
end

describe "BUGS13 T22 block indent survives the HTML round-trip" do
  it "exports indent as margin-left:Nch and parses it back" do
    doc = Crysterm::TextDocument.new("cont")
    doc.blocks[0].block_format = TextBlockFormat.new(indent: 3)
    exported = doc.to_html
    exported.should contain "margin-left:3ch"
    html_doc(exported).blocks[0].block_format.indent.should eq 3
  end
end

describe "BUGS13 T30 huge CSS margins do not crash the importer" do
  it "clamps margin-top/margin-bottom instead of raising OverflowError" do
    doc = html_doc %(<p style="margin-top:99999999999em;margin-bottom:88888888888888em">x</p><p>y</p>)
    doc.to_plain_text.should eq "x\ny"
    doc.blocks[0].block_format.top_margin.should eq 1000
    doc.blocks[0].block_format.bottom_margin.should eq 1000
  end

  it "clamps huge px margins too" do
    doc = html_doc %(<p style="margin-top:999999999999999999999px">x</p>)
    doc.to_plain_text.should eq "x"
    doc.blocks[0].block_format.top_margin.should eq 1000
  end
end
