require "./spec_helper"

include Crysterm

# The block border families (`BorderType::Outer`/`Inner`): edge-anchored block
# ink sized by `Border#ratio` (aspect-compensated, tier-quantized through the
# `Glyphs::SeqRole::BorderRamp*`/`BorderElbow*`/`BorderMiter*` step tables),
# plus the shared `Shadow#ratio` thin-shadow derivation in its complement
# (ground-glyph) encoding.

private def rows(s)
  (0...s.lines.size).map do |y|
    row = s.lines[y]
    (0...row.size).map { |x| row[x].char }.join
  end
end

# Pin the axis compensation the resolutions under test assume: height = 2x
# width, the library default, restored around each example so a device-probed
# value from another spec can't skew the eighth math.
private def with_aspect(aspect = 2.0, &)
  saved = Crysterm::CSS::Length.cell_aspect_ratio
  Crysterm::CSS::Length.cell_aspect_ratio = aspect
  begin
    yield
  ensure
    Crysterm::CSS::Length.cell_aspect_ratio = saved
  end
end

describe "block border families" do
  it "resolves an Outer :half octet at the Unicode tier" do
    with_aspect do
      g = Border.new(type: :outer).glyph_octet(Glyphs::Tier::Unicode)
      # ratio 0.5 → sides 4/8 of width; top/bottom 2/8 of height, which the
      # Unicode tier snaps to the shared 1/8 step on *both* runs of the axis,
      # keeping the frame's opposite edges symmetric.
      g[:l].should eq '▌'
      g[:r].should eq '▐'
      g[:t].should eq '▔'
      g[:b].should eq '▁'
      # Corner steps by the thicker arm (4/8): the three-quadrant elbows.
      {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'▛', '▜', '▙', '▟'})
    end
  end

  it "resolves the exact missing steps at the Extended tier" do
    with_aspect do
      g = Border.new(type: :outer).glyph_octet(Glyphs::Tier::Extended)
      g[:t].should eq '\u{1FB82}' # upper 2/8 — Legacy Computing
      g[:b].should eq '▂'
      g[:l].should eq '▌'
      g[:tl].should eq '▛'
    end
  end

  it "resolves :thin to the eighth ring, with L-corners at Extended" do
    with_aspect do
      b = Border.new(type: :outer, ratio: :thin)
      g = b.glyph_octet(Glyphs::Tier::Unicode)
      {g[:t], g[:b], g[:l], g[:r]}.should eq({'▔', '▁', '▏', '▕'})
      g[:tl].should eq '▛' # no eighth-L in the Unicode repertoire: quadrant
      ge = b.glyph_octet(Glyphs::Tier::Extended)
      {ge[:tl], ge[:tr], ge[:bl], ge[:br]}.should eq({'\u{1FB7D}', '\u{1FB7E}', '\u{1FB7C}', '\u{1FB7F}'})
    end
  end

  it "resolves :full to the tier-independent full-column frame" do
    with_aspect do
      g = Border.new(type: :outer, ratio: :full).glyph_octet(Glyphs::Tier::Unicode)
      {g[:t], g[:b], g[:l], g[:r]}.should eq({'▀', '▄', '█', '█'})
      g[:tl].should eq '█'
    end
  end

  it "flips every anchor for Inner and continues the runs through the corners" do
    with_aspect do
      g = Border.new(type: :inner).glyph_octet(Glyphs::Tier::Unicode)
      # Content-facing anchors: top run inks the cell bottom, left run the
      # cell right — each ramp serves the opposite side.
      {g[:t], g[:b], g[:l], g[:r]}.should eq({'▁', '▔', '▐', '▌'})
      # Corners continue the horizontal strokes at run thickness — no corner
      # bead: the vertical bars meet the full-width strokes flush.
      {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'▁', '▁', '▔', '▔'})
    end
  end

  it "lets explicit char overrides outrank the derived glyphs" do
    with_aspect do
      b = Border.new(type: :outer)
      b.top_char = '━'
      b.corner_char = '+'
      g = b.glyph_octet(Glyphs::Tier::Unicode)
      g[:t].should eq '━'
      g[:tl].should eq '+'
      g[:b].should eq '▁' # untouched positions keep the ramp glyph
    end
  end

  it "accepts named presets and rejects unknown ones" do
    Border.new(ratio: :quarter).ratio.should eq 0.25
    b = Border.new
    b.ratio = :full
    b.ratio.should eq 1.0
    expect_raises(ArgumentError, /Unknown border ratio/) { b.ratio = :bogus }
  end

  it "coerces border type symbols in Border.from without breaking side symbols" do
    Border.from(:outer).type.should eq BorderType::Outer
    Border.from(:inner).type.should eq BorderType::Inner
    side = Border.from(:right)
    side.right.should eq 1
    side.left.should eq 0
  end

  it "renders an Outer :full ring flush to the box edges" do
    with_aspect do
      s = headless_screen(6, 4)
      s.alloc
      b = Widget::Box.new(left: 0, top: 0, width: 6, height: 4, content: "")
      b.style.border = Border.new(type: :outer, ratio: :full)
      s << b
      s.repaint
      r = rows s
      r[0].should eq "█▀▀▀▀█"
      r[1].should eq "█    █"
      r[2].should eq "█    █"
      r[3].should eq "█▄▄▄▄█"
    end
  end

  it "grounds an Inner border transparently by default" do
    with_aspect do
      s = headless_screen(8, 5)
      s.alloc
      backdrop = Widget::Box.new(left: 0, top: 0, width: 8, height: 5, content: "")
      backdrop.style.bg = 0x111111
      s << backdrop
      b = Widget::Box.new(left: 1, top: 1, width: 6, height: 3, content: "")
      b.style.bg = 0x222222
      b.style.border = Border.new(type: :inner, fg: 0xffffff)
      s << b
      s.repaint
      # The border cell keeps the backdrop's bg behind its ink (implied
      # transparent ground) while an interior cell carries the widget bg.
      Attr.bg(s.lines[1][1].attr).should eq 0x111111
      Attr.bg(s.lines[2][3].attr).should eq 0x222222
      # An explicit bg still overrides the implied ground (fresh widget: the
      # frame-resolved style of an already-rendered one is re-resolved, so
      # mutating it after the fact wouldn't stick).
      b2 = Widget::Box.new(left: 1, top: 1, width: 6, height: 3, content: "")
      b2.style.bg = 0x222222
      b2.style.border = Border.new(type: :inner, fg: 0xffffff, bg: 0x333333)
      s << b2
      s.repaint
      Attr.bg(s.lines[1][1].attr).should eq 0x333333
    end
  end

  it "parses the outer/inner CSS keywords and border-ratio" do
    with_aspect do
      style = Style.new
      Crysterm::CSS::Properties.apply style, "border", "outer red"
      style.border.not_nil!.type.should eq BorderType::Outer
      Crysterm::CSS::Properties.apply style, "border-ratio", "37.5%"
      style.border.not_nil!.ratio.should eq 0.375
      Crysterm::CSS::Properties.apply style, "border-ratio", "thin"
      style.border.not_nil!.ratio.should eq 0.125
      Crysterm::CSS::Properties.apply style, "border-ratio", "0.75"
      style.border.not_nil!.ratio.should eq 0.75
      # Invalid declarations are dropped whole.
      Crysterm::CSS::Properties.apply style, "border-ratio", "2.5"
      style.border.not_nil!.ratio.should eq 0.75
      Crysterm::CSS::Properties.apply style, "border-style", "inner"
      style.border.not_nil!.type.should eq BorderType::Inner
    end
  end
end

describe "thin shadow ratio" do
  it "derives the complement ground glyphs per band" do
    with_aspect do
      sh = Shadow.new(right: 1, bottom: 1, ratio: :half)
      g = sh.glyph_octet(Glyphs::Tier::Unicode)
      # ratio 0.5: sides 4/8, top/bottom 2/8 (aspect) → grounds 4/8 and 6/8.
      g[:b].should eq '▆' # lower 6/8 ground; shadow = top 2/8, hugging the box
      g[:r].should eq '▐' # right 4/8 ground; shadow = left 4/8
      g[:l].should eq '▌'
      # Top ground would be 6/8 upper — Unicode caps at the 4/8 step.
      g[:t].should eq '▀'
      # Corners continue the horizontal band's strip (shifted-silhouette
      # shape), instead of squaring up to an elbow that would bulge past it.
      g[:br].should eq '▆'
      g[:bl].should eq '▆'
    end
  end

  it "degrades whole-cell bands to a plain blend at :full and honors overrides" do
    with_aspect do
      g = Shadow.new(ratio: :full).glyph_octet(Glyphs::Tier::Unicode)
      # A full column consumes the side bands' whole cells (no glyph → plain
      # blend); top/bottom ink its on-screen equivalent, half a cell.
      g[:r].nil?.should be_true
      g[:l].nil?.should be_true
      g[:b].should eq '▄'
      sh = Shadow.new(right: 1, bottom: 1, ratio: :half, horizontal_char: '▄')
      g = sh.glyph_octet(Glyphs::Tier::Unicode)
      g[:b].should eq '▄' # explicit char wins
      g[:r].should eq '▐' # derived fills the rest
    end
  end

  it "renders a ratio shadow band hugging the box" do
    with_aspect do
      s = headless_screen(8, 5)
      s.alloc
      backdrop = Widget::Box.new(left: 0, top: 0, width: 8, height: 5, content: "")
      backdrop.style.bg = 0x808080
      s << backdrop
      b = Widget::Box.new(left: 0, top: 0, width: 5, height: 3, content: "")
      b.style.bg = 0x2050a0
      b.style.shadow = Shadow.new(right: 1, bottom: 1, ratio: :half)
      s << b
      s.repaint
      r = rows s
      r[3][1].should eq '▆' # bottom band ground, shadow hugging the box above
      r[1][5].should eq '▐' # right band ground, shadow hugging the box left
      r[3][5].should eq '▆' # corner: the bottom strip continues through it
    end
  end
end
