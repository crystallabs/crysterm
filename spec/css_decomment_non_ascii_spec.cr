require "./spec_helper"

include Crysterm

# `Stylesheet.parse` strips comments by byte: indexing a String by character
# walks it from the start once it holds a multi-byte character, which made
# the pass quadratic on a large sheet with an em dash in a comment — the
# generated theme's rules carry such comments, and a built-in Qt theme lays
# 60 KB of sheet under them.
describe "Stylesheet comments in a sheet with non-ASCII text" do
  it "strips them around quoted strings as before" do
    sheet = Crysterm::CSS::Stylesheet.parse <<-CSS
      /* a note — with a dash, and a 'quote */
      Box { content: "/* not a comment — kept */"; color: red; /* trailing → */ }
      Label { content: 'it\\'s /* kept */'; }
      CSS
    sheet.rules.size.should eq 2
    sheet.rules[0].declarations["content"].should eq %("/* not a comment — kept */")
    sheet.rules[0].declarations["color"].should eq "red"
    sheet.rules[1].declarations["content"].should eq %('it\\'s /* kept */')
  end

  it "parses a large sheet under a non-ASCII comment in linear time" do
    big = String.build do |io|
      2000.times { |i| io << "Box.c" << i << " { color: red; } /* rule " << i << " */\n" }
    end
    ascii = Time.measure { Crysterm::CSS::Stylesheet.parse(big) }
    dashed = Time.measure { Crysterm::CSS::Stylesheet.parse("/* — */\n" + big) }
    # Quadratic, the dashed parse took seconds against the ASCII one's
    # milliseconds; linear, the two are alike. A loose bound, for a loaded
    # machine.
    dashed.should be < [ascii * 20, 1.second].max
  end
end
