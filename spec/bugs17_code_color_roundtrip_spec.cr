require "./spec_helper"

include Crysterm

# BUGS17 B17-30 — HTML export must emit the color <span> innermost (inside the
# <code> tag) so that a re-import folds a code fragment's explicit fg/bg after
# the code element's patch, letting the explicit colors win. Pure model
# (`TextHtml`).

describe "BUGS17 B17-30 code fragment color survives HTML round-trip" do
  it "keeps a recolored code fragment's fg after from_html(to_html)" do
    doc = Crysterm::TextDocument.from_markdown("`x`")
    doc.cursor(0, 1).merge_char_format(Crysterm::TextCharFormat.new(fg: 0xFF0000))

    frag = doc.blocks[0].fragments[0]
    frag.format.code?.should be_true
    frag.format.fg.should eq 0xFF0000

    round = Crysterm::TextDocument.from_html(doc.to_html)
    rfrag = round.blocks[0].fragments[0]
    rfrag.format.code?.should be_true
    # The explicit red must survive.
    rfrag.format.fg.should eq 0xFF0000
  end

  it "still round-trips a link fragment (anchor stays outermost)" do
    doc = Crysterm::TextDocument.from_markdown("[y](http://example.com)")
    round = Crysterm::TextDocument.from_html(doc.to_html)
    rfrag = round.blocks[0].fragments[0]
    rfrag.format.anchor_href.should eq "http://example.com"
    rfrag.text.should eq "y"
  end
end
