require "./spec_helper"

include Crysterm

private PLACEHOLDER = Glyphs.str(Glyphs::Role::IconImage, Glyphs::Tier::Extended)

describe "Markdown images" do
  it "degrade to the picture-frame glyph and alt text in a paragraph" do
    doc = TextDocument.new
    doc.set_markdown "see ![a cat](cat.png) here and ![](blank.png)."
    doc.plain_text.should eq "see #{PLACEHOLDER} a cat here and #{PLACEHOLDER} ."
  end

  it "degrade the same way inside a GFM table cell" do
    doc = TextDocument.new
    doc.set_markdown "| ASCII | Capture | Terminal |\n|:-:|:-:|:-:|\n| `s` | ![](save.png) | 💾 |\n| t | ![tag icon](tag.png) | 🏷 |\n"
    text = doc.plain_text
    row = text.lines.find!(&.includes?("│   s   │"))
    row.split("│").map(&.strip).should eq ["", "s", PLACEHOLDER, "💾", ""]
    text.should contain "#{PLACEHOLDER} tag icon"
  end
end
