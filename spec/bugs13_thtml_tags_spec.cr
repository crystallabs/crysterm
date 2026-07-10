require "./spec_helper"

include Crysterm

# BUGS13 T4/T21/T32 — tags interchange (`TextTags`): checkbox checked state,
# comma/semicolon-combined tags, and out-of-range numeric block props.

describe "BUGS13 T4 checkbox checked state round-trips through tags" do
  it "emits and parses the checked prop" do
    doc = Crysterm::TextDocument.from_tags("{!block;list-checkbox}todo\n{!block;list-checkbox;checked}done")
    doc.blocks[0].block_format.checked?.should be_false
    doc.blocks[1].block_format.checked?.should be_true

    tags = doc.to_tags
    tags.should contain "checked"

    back = Crysterm::TextDocument.from_tags(tags)
    back.blocks[0].block_format.checked?.should be_false
    back.blocks[1].block_format.checked?.should be_true
    back.blocks[1].block_format.list_format.try(&.style.checkbox?).should be_true
  end

  it "carries checked state from HTML task lists into tags" do
    doc = Crysterm::TextDocument.from_html(%(<ul><li><input type="checkbox" checked disabled>x</li></ul>))
    back = Crysterm::TextDocument.from_tags(doc.to_tags)
    back.blocks[0].block_format.checked?.should be_true
  end
end

describe "BUGS13 T21 comma/semicolon-combined tags apply each part" do
  it "parses {bold,underline} as both attributes" do
    doc = Crysterm::TextDocument.from_tags("{bold,underline}x{/bold,underline}y")
    f = doc.blocks[0].fragments
    f[0].text.should eq "x"
    f[0].format.bold?.should be_true
    f[0].format.underline?.should be_true
    f[1].text.should eq "y"
    f[1].format.bold?.should be_false
    f[1].format.underline?.should be_false
  end

  it "parses semicolon-combined tags too" do
    doc = Crysterm::TextDocument.from_tags("{bold;red-fg}x{/bold;red-fg}")
    f = doc.blocks[0].fragments[0]
    f.format.bold?.should be_true
    f.format.fg.should_not be_nil
  end
end

describe "BUGS13 T32 out-of-range numeric block props drop instead of raising" do
  it "drops a huge mt- prop" do
    doc = Crysterm::TextDocument.from_tags("{!block;mt-99999999999}x")
    doc.to_plain_text.should eq "x"
    doc.blocks[0].block_format.top_margin.should eq 0
  end

  it "drops huge mb-/indent-/q-/li-/ls- props, keeping valid ones" do
    doc = Crysterm::TextDocument.from_tags("{!block;mb-99999999999;indent-99999999999;q-99999999999;mt-2}x")
    doc.to_plain_text.should eq "x"
    bf = doc.blocks[0].block_format
    bf.bottom_margin.should eq 0
    bf.indent.should eq 0
    bf.quote_level.should eq 0
    bf.top_margin.should eq 2
  end

  it "falls back to defaults for huge list li-/ls- props" do
    doc = Crysterm::TextDocument.from_tags("{!block;list-decimal;li-99999999999;ls-99999999999}x")
    lf = doc.blocks[0].block_format.list_format
    lf.should_not be_nil
    lf.try(&.indent).should eq 1
    lf.try(&.start).should eq 1
  end
end
