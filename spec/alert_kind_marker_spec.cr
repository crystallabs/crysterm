require "./spec_helper"

# `TextBlockFormat::AlertKind`'s title (GitHub's) and the title chip a view
# paints at an alert block's text start, which `TextEdit` and any text
# rendering of the document share.
describe Crysterm::TextBlockFormat::AlertKind do
  it "has GitHub's titles" do
    Crysterm::TextBlockFormat::AlertKind.values.map(&.title).should eq ["Note", "Tip", "Important", "Warning", "Caution"]
  end

  it "makes the chip of its icon and title" do
    note = Crysterm::TextBlockFormat::AlertKind::Note
    note.marker.should eq "#{Crysterm::Glyphs[Crysterm::Glyphs::Role::IconInfo, Crysterm::Glyphs::Tier::Unicode]} NOTE "
    note.marker(Crysterm::Glyphs::Tier::Ascii).should eq "#{Crysterm::Glyphs[Crysterm::Glyphs::Role::IconInfo, Crysterm::Glyphs::Tier::Ascii]} NOTE "
  end

  it "is the chip the viewer paints" do
    s = headless_screen(40, 6)
    tb = Crysterm::Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 4
    tb.markdown = "> [!WARNING]\n> careful\n"
    s.repaint
    row = (0...30).map { |x| s.cell_rows[0][x].char }.join.rstrip
    row.should end_with "#{Crysterm::TextBlockFormat::AlertKind::Warning.marker(tb.glyph_tier)}careful"
  end
end
