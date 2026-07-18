require "./spec_helper"

include Crysterm

# The central `Crysterm::Glyphs` registry (GLYPHS.md phase 1): one place
# defines every chrome glyph per support tier (`Ascii < Unicode < Extended`),
# `Screen#glyph_tier` picks the set (default `Unicode` — byte-identical with
# the historically hardcoded literals), and widgets resolve through
# `Widget#glyph`/`BorderType#line_glyphs(tier)`/`Docking.dock(..., ascii)`.
private def screen(width, height)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

private def rows(s)
  (0...s.lines.size).map do |y|
    row = s.lines[y]
    (0...row.size).map { |x| row[x].char }.join
  end
end

describe Crysterm::Glyphs do
  it "falls down tiers within an entry" do
    e = Glyphs::Entry.new('a', 'u', 'x')
    e.for(Glyphs::Tier::Extended).should eq 'x'
    e.for(Glyphs::Tier::Unicode).should eq 'u'
    e.for(Glyphs::Tier::Ascii).should eq 'a'

    e = Glyphs::Entry.new('a', 'u')
    e.for(Glyphs::Tier::Extended).should eq 'u' # no extended -> unicode
    e = Glyphs::Entry.new('a')
    e.for(Glyphs::Tier::Extended).should eq 'a' # ascii-only entry
    e.for(Glyphs::Tier::Unicode).should eq 'a'
  end

  it "answers the historical literals at tier Unicode" do
    t = Glyphs::Tier::Unicode
    Glyphs[Glyphs::Role::BorderLineTL, t].should eq '┌'
    Glyphs[Glyphs::Role::BorderDoubleH, t].should eq '═'
    Glyphs[Glyphs::Role::ScrollThumb, t].should eq '█'
    Glyphs[Glyphs::Role::ScrollTrough, t].should eq '░'
    Glyphs[Glyphs::Role::SubmenuArrow, t].should eq '▶'
    Glyphs[Glyphs::Role::DropdownArrow, t].should eq '▾'
    Glyphs[Glyphs::Role::CloseButton, t].should eq '✕'
    Glyphs[Glyphs::Role::FloatButton, t].should eq '⇕'
    Glyphs[Glyphs::Role::SizeGrip, t].should eq '◢'
    Glyphs[Glyphs::Role::TreeExpanded, t].should eq '▾'
    Glyphs[Glyphs::Role::TreeCollapsed, t].should eq '▸'
    Glyphs[Glyphs::Role::CursorBar, t].should eq '│'
    # Historically-ASCII marks stay ASCII at tier Unicode (no unicode override).
    Glyphs[Glyphs::Role::CheckboxChecked, t].should eq 'x'
    Glyphs[Glyphs::Role::CheckboxOpen, t].should eq '['
    Glyphs[Glyphs::Role::RadioChecked, t].should eq '*'
  end

  it "answers 7-bit characters for every role at tier Ascii" do
    Glyphs::Role.each do |role|
      Glyphs[role, Glyphs::Tier::Ascii].ord.should be < 128
    end
  end

  it "defines an explicit entry for every role (none left at the blank placeholder)" do
    # Roles whose ascii rendition legitimately IS a space.
    blank_ok = Set{Glyphs::Role::CheckboxUnchecked, Glyphs::Role::RadioUnchecked,
                   Glyphs::Role::TreeLeaf}
    Glyphs::Role.each do |role|
      next if blank_ok.includes? role
      Glyphs[role, Glyphs::Tier::Ascii].should_not(eq(' '), "role #{role} has no DEFAULTS row")
    end
  end

  it "answers single-width glyphs at tiers Ascii and Unicode for every role" do
    # Only the `extended` column may hold double-width (emoji) icons; the
    # ascii/unicode columns must stay one cell so chrome consumers never widen.
    Glyphs::Role.each do |role|
      {Glyphs::Tier::Ascii, Glyphs::Tier::Unicode}.each do |tier|
        ch = Glyphs[role, tier]
        Crysterm::Unicode.display_width(ch.to_s).should(eq(1), "role #{role} at #{tier} (#{ch.inspect}) is not single-width")
      end
    end
  end

  it "carries multi-codepoint graphemes in the String columns (emoji-presentation)" do
    ext = Glyphs::Tier::Extended
    # `⚠️` = U+26A0 + VS16: two codepoints a `Char` can't hold. The widened
    # `extended` String column carries it; `str` returns it whole.
    warn = Glyphs.str(Glyphs::Role::IconWarningSign, ext)
    warn.should eq "⚠️"
    warn.codepoints.size.should eq 2
    # `char?` reports the fast-lane single codepoint, or nil for a cluster.
    Glyphs.char?(Glyphs::Role::IconWarningSign, ext).should be_nil
    Glyphs.char?(Glyphs::Role::IconWarningSign, Glyphs::Tier::Unicode).should eq '⚠'
    # A cell-role `[]` read still reject-to-falls-back to a lone codepoint,
    # never widening: extended's cluster drops to the single unicode symbol.
    Glyphs[Glyphs::Role::IconWarningSign, ext].should eq '⚠'
    # A lone-codepoint role answers the same char through all three accessors.
    Glyphs.str(Glyphs::Role::BorderLineTL, Glyphs::Tier::Unicode).should eq "┌"
    Glyphs.char?(Glyphs::Role::BorderLineTL, Glyphs::Tier::Unicode).should eq '┌'
  end

  it "accepts both Char and String overrides via set" do
    begin
      Glyphs.set Glyphs::Role::IconWarning, extended: "⚠️" # String
      Glyphs.str(Glyphs::Role::IconWarning, Glyphs::Tier::Extended).should eq "⚠️"
      Glyphs.set Glyphs::Role::IconWarning, unicode: '!' # Char still works
      Glyphs[Glyphs::Role::IconWarning, Glyphs::Tier::Unicode].should eq '!'
    ensure
      Glyphs.reset
    end
  end

  it "retunes roles via set and restores via reset, bumping the generation" do
    gen = Glyphs.generation
    Glyphs.set Glyphs::Role::ScrollThumb, unicode: '▓'
    begin
      Glyphs.generation.should eq gen + 1
      Glyphs[Glyphs::Role::ScrollThumb, Glyphs::Tier::Unicode].should eq '▓'
      # Other tiers of the same role keep their values.
      Glyphs[Glyphs::Role::ScrollThumb, Glyphs::Tier::Ascii].should eq '#'
    ensure
      Glyphs.reset
    end
    Glyphs[Glyphs::Role::ScrollThumb, Glyphs::Tier::Unicode].should eq '█'
    Glyphs.generation.should be > gen + 1
  end
end

describe "Screen#glyph_tier" do
  it "defaults to Unicode and is settable through the window" do
    s = screen 4, 4
    begin
      s.glyph_tier.should eq Glyphs::Tier::Unicode
      s.glyph_tier = Glyphs::Tier::Ascii
      s.glyph_tier.should eq Glyphs::Tier::Ascii
    ensure
      # Destroy so the ascii-tier window doesn't linger as the global-window
      # fallback that a detached widget's `glyph_tier` resolves through.
      s.destroy
    end
  end

  it "resolves Widget#glyph to Unicode when unattached" do
    b = Crysterm::Widget::Box.new
    b.glyph_tier.should eq Glyphs::Tier::Unicode
    b.glyph(Glyphs::Role::BorderLineTL).should eq '┌'
  end
end

describe "tier-aware rendering" do
  it "draws a Line border with box glyphs at Unicode and + - | at Ascii" do
    { {Glyphs::Tier::Unicode, "┌──┐", "│  │", "└──┘"},
     {Glyphs::Tier::Ascii, "+--+", "|  |", "+--+"} }.each do |(tier, top, mid, bot)|
      s = screen 4, 3
      s.glyph_tier = tier
      s.alloc
      b = Crysterm::Widget::Box.new(left: 0, top: 0, width: 4, height: 3, content: "")
      b.style.border = Crysterm::Border.new(type: Crysterm::BorderType::Solid)
      s << b
      s._render

      r = rows s
      r[0].should eq top
      r[1].should eq mid
      r[2].should eq bot
      s.destroy
    end
  end

  it "keeps CheckBox / RadioButton markers identical across Ascii and Unicode tiers" do
    {Glyphs::Tier::Unicode, Glyphs::Tier::Ascii}.each do |tier|
      s = screen 10, 2
      s.glyph_tier = tier
      s.alloc
      cb = Crysterm::Widget::CheckBox.new(checked: true, content: "c", left: 0, top: 0, width: 10, height: 1)
      rb = Crysterm::Widget::RadioButton.new(checked: true, content: "r", left: 0, top: 1, width: 10, height: 1)
      s << cb
      s << rb
      s._render

      r = rows s
      r[0].should start_with "[x] c"
      r[1].should start_with "(*) r"
      s.destroy
    end
  end

  it "docks adjacent borders to ASCII junctions at tier Ascii" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 7, height: 3, dock_borders: true)
    s.glyph_tier = Glyphs::Tier::Ascii
    s.alloc
    b1 = Crysterm::Widget::Box.new(left: 0, top: 0, width: 4, height: 3, content: "")
    b1.style.border = Crysterm::Border.new(type: Crysterm::BorderType::Solid)
    b2 = Crysterm::Widget::Box.new(left: 3, top: 0, width: 4, height: 3, content: "")
    b2.style.border = Crysterm::Border.new(type: Crysterm::BorderType::Solid)
    s << b1
    s << b2
    s._render

    r = rows s
    # The shared column (x=3) docks: `+` would be `┬`/`┴` in Unicode.
    r[0].should eq "+--+--+"
    r[1].should eq "|  |  |"
    r[2].should eq "+--+--+"
    s.destroy
  end
end
