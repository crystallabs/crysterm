require "./spec_helper"

include Crysterm

# markd percent-encodes every non-ASCII byte of a destination at parse time;
# the exporter writes those escapes back as the characters, and keeps the
# escapes of ASCII bytes, of invalid UTF-8 and of characters unsafe to read raw.
private def href_of(doc : TextDocument) : String?
  doc.blocks.flat_map(&.fragments.to_a).compact_map(&.format.anchor_href).first?
end

private def round_trip(md : String) : {String, String?, String?}
  doc = TextDocument.from_markdown(md)
  exported = doc.to_markdown
  {exported, href_of(doc), href_of(TextDocument.from_markdown(exported))}
end

describe "Markdown export of a destination holding non-ASCII characters" do
  it "writes a link destination's characters as the author did" do
    exported, before, after = round_trip("[x](ćevapi.png)")
    exported.should eq "[x](ćevapi.png)"
    before.should eq "%C4%87evapi.png"
    after.should eq before
  end

  it "keeps the path, query and fragment around them" do
    md = "[x](https://hr.wikipedia.org/wiki/Ćevapi#Povijest)"
    exported, before, after = round_trip(md)
    exported.should eq md
    after.should eq before
  end

  it "writes a block image's source as the author did" do
    doc = TextDocument.from_markdown("![alt](ćevapi.png)")
    doc.blocks.first.block_format.image.not_nil!.name.should eq "%C4%87evapi.png"
    doc.to_markdown.should eq "![alt](ćevapi.png)"
    TextDocument.from_markdown(doc.to_markdown).blocks.first.block_format.image.not_nil!.name
      .should eq "%C4%87evapi.png"
  end

  it "writes escapes the author typed for a character as that character, the same URL" do
    exported, before, after = round_trip("[x](%C4%87)")
    exported.should eq "[x](ć)"
    after.should eq before
  end

  it "keeps the escapes of ASCII bytes" do
    round_trip("[x](a%20b)")[0].should eq "[x](a%20b)"
    round_trip("[x](a?q=%25)")[0].should eq "[x](a?q=%25)"
  end

  it "keeps the escapes of invalid UTF-8 and of whitespace and format characters" do
    {"[x](a%C4b)", "[x](a%C2%A0b)", "[x](a%E2%80%AEb)", "[x](a%E2%80%8Bb)"}.each do |md|
      exported, before, after = round_trip(md)
      exported.should eq md
      after.should eq before
    end
  end
end
