require "./spec_helper"

include Crysterm

# Every extended-tier glyph in the emoji blocks (U+1F300..1FAFF; the
# legacy-computing symbols above them are one-column drawing pieces) must
# measure two columns: either an emoji-presentation character, or a
# text-presentation one made emoji with VS16. A bare text-presentation
# pictograph is counted one column but drawn two wide by the color emoji font
# a terminal falls back to for it, so whatever follows overlaps the glyph.
describe "extended-tier pictographs" do
  it "measure two columns in the emoji blocks" do
    # The window controls 🗕 🗖 (U+1F5D5, U+1F5D6) are pictographs with no
    # emoji presentation at all (not in Unicode's `Emoji` property), so VS16
    # cannot apply and no color font draws them: text symbols, one column.
    not_emoji = [Glyphs::Role::IconMinimize, Glyphs::Role::IconMaximize]
    narrow = [] of String
    Glyphs::Role.each do |role|
      ext = Glyphs.entry(role).extended
      next unless ext
      next unless 0x1F300 <= ext[0].ord <= 0x1FAFF
      next if not_emoji.includes? role
      narrow << "#{role}: #{ext.inspect}" unless Tput::Unicode.display_width(ext) == 2
    end
    narrow.should be_empty
    not_emoji.each { |role| Tput::Unicode.display_width(Glyphs.entry(role).extended.to_s).should eq 1 }
  end

  it "give the mouse and picture icons their emoji presentation" do
    Glyphs.str(Glyphs::Role::IconMouse, Glyphs::Tier::Extended).should eq "🖱\u{FE0F}"
    Glyphs.str(Glyphs::Role::IconImage, Glyphs::Tier::Extended).should eq "🖼\u{FE0F}"
    # The cell-role accessor still answers with a lone codepoint.
    Glyphs[Glyphs::Role::IconMouse, Glyphs::Tier::Extended].should eq 'M'
    Glyphs[Glyphs::Role::IconImage, Glyphs::Tier::Extended].should eq '▣'
  end
end
