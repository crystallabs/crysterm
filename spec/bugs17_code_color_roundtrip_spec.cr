require "./spec_helper"

include Crysterm

# BUGS17 B17-30 — HTML export must emit the color <span> innermost (inside the
# <code> tag) so that a re-import folds a code fragment's explicit fg/bg after
# the code element's theme-fallback patch, letting the explicit colors win.
# Otherwise `from_html(to_html(doc))` clobbers a recolored code fragment with
# the theme's code colors. Pure model (`TextHtml`).

describe "BUGS17 B17-30 code fragment color survives HTML round-trip" do
  it "keeps a recolored code fragment's fg after from_html(to_html)" do
    doc = Crysterm::TextDocument.from_markdown("`x`")
    doc.apply_char_format(0, 1, Crysterm::TextCharFormat.new(fg: 0xFF0000), merge: true)

    frag = doc.blocks[0].fragments[0]
    frag.format.code?.should be_true
    frag.format.fg.should eq 0xFF0000

    round = Crysterm::TextDocument.from_html(doc.to_html)
    rfrag = round.blocks[0].fragments[0]
    rfrag.format.code?.should be_true
    # The explicit red must survive, not be replaced by the theme's code color.
    rfrag.format.fg.should eq 0xFF0000
    rfrag.format.fg.should_not eq Crysterm::TextTheme.default.code_color
  end

  it "still round-trips a link fragment (anchor stays outermost)" do
    doc = Crysterm::TextDocument.from_markdown("[y](http://example.com)")
    round = Crysterm::TextDocument.from_html(doc.to_html)
    rfrag = round.blocks[0].fragments[0]
    rfrag.format.anchor_href.should eq "http://example.com"
    rfrag.text.should eq "y"
  end
end
