require "./spec_helper"

include Crysterm

# The border stroke axes (plans/BORDERS.md): `Border#type`/`#pattern`/
# `#align`/`#corners`/`#corner_ratio`, the `BorderType` preset mapping over
# them, the light-driven relief machinery (`Light`, `Border#relief_style`,
# shadow auto-placement) and the `Style#look` presets.

private def with_aspect(aspect = 2.0, &)
  saved = Crysterm::CSS::Length.cell_aspect_ratio
  Crysterm::CSS::Length.cell_aspect_ratio = aspect
  begin
    yield
  ensure
    Crysterm::CSS::Length.cell_aspect_ratio = saved
  end
end

private def rows(s)
  (0...s.lines.size).map do |y|
    row = s.lines[y]
    (0...row.size).map { |x| row[x].char }.join
  end
end

# An 8x6 box carrying *border*, rendered on a fresh headless screen and read
# back as rows — the band-alignment examples' shared fixture.
private def band_rows(border : Crysterm::Border) : Array(String)
  s = headless_screen(8, 6)
  s.alloc
  b = Crysterm::Widget::Box.new(left: 0, top: 0, width: 8, height: 6, content: "")
  b.style.border = border
  s << b
  s.repaint
  (0...6).map { |y| (0...8).map { |x| s.lines[y][x].char }.join }
end

describe "border stroke axes" do
  it "fans presets out over the axes and derives them back" do
    b = Border.new
    {
      BorderType::Solid   => {Border::Medium::Line, Border::Pattern::Solid, Border::Align::Center},
      BorderType::Dashed  => {Border::Medium::Line, Border::Pattern::Dashed, Border::Align::Center},
      BorderType::Dotted  => {Border::Medium::Line, Border::Pattern::Dotted, Border::Align::Center},
      BorderType::Double  => {Border::Medium::Line, Border::Pattern::Double, Border::Align::Center},
      BorderType::Rounded => {Border::Medium::Line, Border::Pattern::Solid, Border::Align::Center},
      BorderType::Outer   => {Border::Medium::Block, Border::Pattern::Solid, Border::Align::Outer},
      BorderType::Inner   => {Border::Medium::Block, Border::Pattern::Solid, Border::Align::Inner},
      BorderType::Braille => {Border::Medium::Braille, Border::Pattern::Solid, Border::Align::Outer},
      BorderType::Fill    => {Border::Medium::Fill, Border::Pattern::Solid, Border::Align::Center},
    }.each do |preset, (medium, pattern, align)|
      b.type = preset
      b.type.medium.should eq medium
      b.pattern.should eq pattern
      b.align.should eq align
      b.type.should eq preset
    end
    b.type = :rounded
    b.corners.uniform.should eq Border::Corner::Rounded
    b.type = :solid
    b.corners.uniform.should eq Border::Corner::Square
  end

  it "constructs from axis arguments (symbols included)" do
    b = Border.new type: :braille, align: :inner, pattern: :dotted, corners: :rounded
    b.type.medium.braille?.should be_true
    b.align.inner?.should be_true
    b.pattern.dotted?.should be_true
    b.corners.uniform.should eq Border::Corner::Rounded
    b.type.should eq BorderType::Braille # nearest-preset compat view
  end

  it "combines dashed patterns with rounded corners (inexpressible pre-axes)" do
    g = Border.new(pattern: :dashed, corners: :rounded).glyph_octet(Glyphs::Tier::Unicode)
    {g[:t], g[:l]}.should eq({'┄', '┆'})
    {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'╭', '╮', '╰', '╯'})
  end

  it "cuts corners with the light diagonals" do
    g = Border.new(corners: :cut).glyph_octet(Glyphs::Tier::Unicode)
    {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'╱', '╲', '╲', '╱'})
    g[:t].should eq '─'
  end

  it "supports per-corner treatments (a tab shape)" do
    b = Border.new
    b.corners = Border::Corners.new(tl: Border::Corner::Rounded, tr: Border::Corner::Rounded)
    g = b.glyph_octet(Glyphs::Tier::Unicode)
    {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'╭', '╮', '└', '┘'})
  end

  it "reads ratio as line weight: heavy above half" do
    g = Border.new(type: :solid, ratio: :full).glyph_octet(Glyphs::Tier::Unicode)
    {g[:t], g[:l], g[:tl], g[:br]}.should eq({'━', '┃', '┏', '┛'})
    gd = Border.new(type: :dotted, ratio: :full).glyph_octet(Glyphs::Tier::Unicode)
    {gd[:t], gd[:l]}.should eq({'┉', '┋'})
    # Double is already the heaviest spelling of its family: unchanged.
    g2 = Border.new(type: :double, ratio: :full).glyph_octet(Glyphs::Tier::Unicode)
    {g2[:t], g2[:tl]}.should eq({'═', '╔'})
  end

  it "rounds a Double's rounded corners down to its own square joins" do
    g = Border.new(type: :double, corners: :rounded).glyph_octet(Glyphs::Tier::Unicode)
    {g[:tl], g[:br]}.should eq({'╔', '╝'})
  end

  it "rounds block Center alignment down to Outer" do
    with_aspect do
      g = Border.new(type: :block, align: :center).glyph_octet(Glyphs::Tier::Unicode)
      {g[:l], g[:t]}.should eq({'▌', '▔'}) # the Outer :half octet
    end
  end

  it "accepts the bare-medium type spellings, collapsing on read-back" do
    b = Border.new(type: :block)
    b.align.outer?.should be_true
    b.type.should eq BorderType::Outer # Block collapses onto its equivalent
    l = Border.new(type: :line)
    l.type.should eq BorderType::Solid
    l.type.medium.line?.should be_true
    # A preset's dash pattern stays overridable per axis.
    d = Border.new(type: :braille, pattern: :dotted)
    d.type.braille?.should be_true
    d.pattern.dotted?.should be_true
  end
end

describe "corner_ratio (corner beads)" do
  it "beads heavy line corners onto light runs" do
    g = Border.new(type: :solid, corner_ratio: :full).glyph_octet(Glyphs::Tier::Unicode)
    {g[:t], g[:l]}.should eq({'─', '│'})
    {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'┏', '┓', '┗', '┛'})
  end

  it "mounts quadrant beads on a hairline outer block ring at every tier" do
    with_aspect do
      {Glyphs::Tier::Unicode, Glyphs::Tier::Extended}.each do |tier|
        g = Border.new(type: :outer, ratio: :thin, corner_ratio: :half).glyph_octet(tier)
        {g[:t], g[:b], g[:l], g[:r]}.should eq({'▔', '▁', '▏', '▕'})
        {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'▛', '▜', '▙', '▟'})
      end
    end
  end

  it "mounts full-dot corner blocks on a one-dot braille ring" do
    with_aspect do
      g = Border.new(type: :braille, ratio: :half, corner_ratio: :full).glyph_octet(Glyphs::Tier::Extended)
      {g[:t], g[:l]}.should eq({'⠉', '⡇'})
      {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'⣿', '⣿', '⣿', '⣿'})
    end
  end
end

describe "braille axes" do
  it "anchors an Inner braille ring flush with the content, corners flush by union" do
    with_aspect do
      g = Border.new(type: :braille, align: :inner).glyph_octet(Glyphs::Tier::Extended)
      {g[:t], g[:b], g[:l], g[:r]}.should eq({'⣀', '⠉', '⢸', '⡇'})
      {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'⣸', '⣇', '⢹', '⡏'})
    end
  end

  it "grounds an Inner braille ring transparently by default" do
    with_aspect do
      s = headless_screen(8, 5)
      s.glyph_tier = Glyphs::Tier::Extended
      s.alloc
      backdrop = Widget::Box.new(left: 0, top: 0, width: 8, height: 5, content: "")
      backdrop.style.bg = 0x111111
      s << backdrop
      b = Widget::Box.new(left: 1, top: 1, width: 6, height: 3, content: "")
      b.style.bg = 0x222222
      b.style.border = Border.new(type: :braille, align: :inner, fg: 0xffffff)
      s << b
      s.repaint
      Attr.bg(s.lines[1][1].attr).should eq 0x111111 # backdrop shows through
      Attr.bg(s.lines[2][3].attr).should eq 0x222222 # interior keeps widget bg
    end
  end

  it "draws sparse dotted and dashed braille patterns" do
    with_aspect do
      g = Border.new(type: :braille, pattern: :dotted).glyph_octet(Glyphs::Tier::Extended)
      {g[:t], g[:b], g[:l], g[:r]}.should eq({'⠁', '⡀', '⠅', '⠨'})
      gd = Border.new(type: :braille, pattern: :dashed).glyph_octet(Glyphs::Tier::Extended)
      {gd[:l], gd[:r]}.should eq({'⠃', '⠘'})
      gd[:t].should eq '⠁' # horizontal dashes round down to dotted
    end
  end

  it "rounds and cuts braille corners at dot scale" do
    with_aspect do
      g = Border.new(type: :braille, corners: :rounded).glyph_octet(Glyphs::Tier::Extended)
      g[:tl].should eq '⡎' # the union ⡏ minus its apex dot
      gc = Border.new(type: :braille, corners: :cut).glyph_octet(Glyphs::Tier::Extended)
      {gc[:tl], gc[:tr], gc[:bl], gc[:br]}.should eq({'⠊', '⠑', '⢄', '⡠'})
    end
  end

  it "degrades a dashed braille pattern to the Dashed line family below Extended" do
    g = Border.new(type: :braille, pattern: :dashed).glyph_octet(Glyphs::Tier::Unicode)
    {g[:t], g[:l]}.should eq({'┄', '┆'})
  end
end

describe "Light" do
  it "classifies sides against the 8-way compass" do
    nw = Light.new(Light::Direction::NW)
    {nw.lit(Crysterm::Side::Top), nw.lit(Crysterm::Side::Left), nw.lit(Crysterm::Side::Bottom), nw.lit(Crysterm::Side::Right)}
      .should eq({1, 1, -1, -1})
    n = Light.new(Light::Direction::N)
    {n.lit(Crysterm::Side::Top), n.lit(Crysterm::Side::Bottom), n.lit(Crysterm::Side::Left), n.lit(Crysterm::Side::Right)}
      .should eq({1, -1, 0, 0})
    n.shadow_side?(Crysterm::Side::Bottom).should be_true
    n.shadow_side?(Crysterm::Side::Right).should be_false
  end

  it "shades relief by the light, leaving neutral sides alone" do
    b = Border.new(fg: 0x808080, relief: :outset)
    base = 0x808080
    nw = Light::DEFAULT
    b.side_fg(Crysterm::Side::Top, nil, nw).not_nil!.should be > base    # lit
    b.side_fg(Crysterm::Side::Bottom, nil, nw).not_nil!.should be < base # shaded
    s_light = Light.new(Light::Direction::S)
    b.side_fg(Crysterm::Side::Bottom, nil, s_light).not_nil!.should be > base # now lit
    b.side_fg(Crysterm::Side::Left, nil, s_light).should eq base              # neutral: untouched
  end

  it "reproduces the legacy top-left shading under the default light" do
    b = Border.new(fg: 0x808080, relief: :inset)
    # Same values side_fg produced before lights existed (NW hardcoded).
    b.side_fg(Crysterm::Side::Top, nil).not_nil!.should be < 0x808080
    b.side_fg(Crysterm::Side::Right, nil).not_nil!.should be > 0x808080
  end
end

describe "weight bevel (relief_style)" do
  it "reproduces the styling.cr hand-made bevel automatically" do
    # styling.cr: dotted family, heavy ━/┃ lit sides, corners ┏ ┑ ┖ (+ base ┘).
    b = Border.new(type: :dotted, relief: :outset, relief_style: :weight)
    g = b.glyph_octet(Glyphs::Tier::Unicode)
    {g[:t], g[:l]}.should eq({'┉', '┋'}) # heavy dotted lit runs
    {g[:b], g[:r]}.should eq({'┈', '┊'}) # shaded keep the light dotted
    {g[:tl], g[:tr], g[:bl], g[:br]}.should eq({'┏', '┑', '┖', '┘'})
  end

  it "expresses weight relief in ink steps for block and dot-lines for braille" do
    with_aspect do
      b = Border.new(type: :outer, relief: :outset, relief_style: :weight)
      g = b.glyph_octet(Glyphs::Tier::Extended)
      # ratio :half = 4/8 sides, 2/8 tops; lit (top/left) bumped one step.
      g[:l].should eq '▋'         # 5/8
      g[:r].should eq '▐'         # 4/8
      g[:t].should eq '\u{1FB83}' # 3/8 upper
      g[:b].should eq '▂'         # 2/8 lower
      br = Border.new(type: :braille, relief: :outset, relief_style: :weight)
      gb = br.glyph_octet(Glyphs::Tier::Extended)
      {gb[:t], gb[:l]}.should eq({'⠛', '⣿'}) # two dot-lines lit
      {gb[:b], gb[:r]}.should eq({'⣀', '⢸'}) # one shaded
    end
  end

  it "keeps colors unshaded when the relief is weight-only" do
    b = Border.new(fg: 0x808080, relief: :outset, relief_style: :weight)
    b.side_fg(Crysterm::Side::Top, nil).should eq 0x808080
    both = Border.new(fg: 0x808080, relief: :outset, relief_style: :both)
    both.side_fg(Crysterm::Side::Top, nil).not_nil!.should be > 0x808080
  end
end

describe "shadow auto-placement" do
  it "resolves auto sides from the light, reproducing the classic under NW" do
    s = Shadow.new
    s.auto_sides?.should be_true
    s.resolved_sides(Light::DEFAULT).should eq({0, 0, 2, 1})
    s.resolved_sides(Light.new(Light::Direction::N)).should eq({0, 0, 0, 1})
    s.resolved_sides(Light.new(Light::Direction::SE)).should eq({2, 1, 0, 0})
    thin = Shadow.new(ratio: :half)
    thin.resolved_sides(Light::DEFAULT).should eq({0, 0, 1, 1})
  end

  it "pins manual placement when any side is explicit" do
    s = Shadow.new(right: 1, bottom: 1)
    s.auto_sides?.should be_false
    s.resolved_sides(Light.new(Light::Direction::N)).should eq({0, 0, 1, 1})
  end

  it "spills an auto Spot shadow one cell past the free band ends" do
    with_aspect do
      s = headless_screen(12, 7)
      s.alloc
      backdrop = Widget::Box.new(left: 0, top: 0, width: 12, height: 7, content: "")
      backdrop.style.bg = 0x808080
      s << backdrop
      b = Widget::Box.new(left: 3, top: 1, width: 5, height: 3, content: "")
      b.style.bg = 0x2050a0
      b.style.shadow = Shadow.new
      b.style.light = Light.new(Light::Direction::N, Light::Kind::Spot)
      s << b
      s.repaint
      # Bottom band only (light N), rows 4, spanning 1 cell past each edge:
      # widget columns 3..7 → shadow columns 2..8.
      Attr.bg(s.lines[4][2].attr).should be < 0x808080
      Attr.bg(s.lines[4][8].attr).should be < 0x808080
      Attr.bg(s.lines[4][1].attr).should eq 0x808080 # beyond the spill
      Attr.bg(s.lines[2][8].attr).should eq 0x808080 # no right band
      # Directional: exact silhouette, columns 3..7 only (fresh screen — the
      # spot widget's shadow already darkened this one).
      s2 = headless_screen(12, 7)
      s2.alloc
      backdrop2 = Widget::Box.new(left: 0, top: 0, width: 12, height: 7, content: "")
      backdrop2.style.bg = 0x808080
      s2 << backdrop2
      b2 = Widget::Box.new(left: 3, top: 1, width: 5, height: 3, content: "")
      b2.style.bg = 0x2050a0
      b2.style.shadow = Shadow.new
      b2.style.light = Light.new(Light::Direction::N)
      s2 << b2
      s2.repaint
      Attr.bg(s2.lines[4][2].attr).should eq 0x808080
      Attr.bg(s2.lines[4][3].attr).should be < 0x808080
    end
  end
end

describe "band alignment and block patterns (width >= 2)" do
  it "keeps 1-cell borders and Center thick bands on the classic geometry" do
    r = band_rows Border.new
    r[0].should eq "┌──────┐"
    r[1].should eq "│      │"
    rc = band_rows Border.new(align: :center, left: 2, top: 2, right: 2, bottom: 2)
    # Every band cell repeats its position's glyph — the pre-axes geometry
    # (corner blocks repeat the corner, runs stack).
    rc[0].should eq "┌┌────┐┐"
    rc[1].should eq "┌┌────┐┐"
  end

  it "rules only the rim ring for an Outer-aligned thick band" do
    r = band_rows Border.new(align: :outer, left: 2, top: 2, right: 2, bottom: 2)
    r[0].should eq "┌──────┐"
    r[1].should eq "│      │" # band ground inside the rim
    r[5].should eq "└──────┘"
  end

  it "rules only the content-hugging ring for an Inner-aligned thick band" do
    r = band_rows Border.new(align: :inner, left: 2, top: 2, right: 2, bottom: 2)
    r[0].should eq "        " # outward band cells are ground
    r[1].should eq " ┌────┐ "
    r[2].should eq " │    │ "
    r[4].should eq " └────┘ "
    r[5].should eq "        "
  end

  it "draws a block Double pattern as two rings at width >= 3" do
    with_aspect do
      r3 = band_rows Border.new(type: :block, pattern: :double, ratio: :full,
        left: 3, top: 3, right: 3, bottom: 3)
      # Rim ring, ground between, content-hugging ring.
      r3[0][4].should eq '▀'
      r3[1][4].should eq ' '
      r3[2][4].should eq '▀'
    end
  end

  it "gaps dashed and dotted block runs by whole cells, corners kept" do
    with_aspect do
      r = band_rows Border.new(type: :block, pattern: :dotted, ratio: :full)
      # Dotted: alternate ink/ground cells along the run, phase-locked to
      # the box edge; the corner cell (offset 0) always inks.
      r[0].should eq "█ ▀ ▀ ▀█"
      r[1].should eq "        " # the side runs gap on odd rows too
      r[2].should eq "█      █"
      rd = band_rows Border.new(type: :block, pattern: :dashed, ratio: :full)
      # Dashed: two ink cells to one ground.
      rd[0].should eq "█▀ ▀▀ ▀█"
    end
  end
end

describe "Style#look" do
  it "expands the presets over relief, rendition and shadow" do
    st = Style.new
    st.look = :raised
    st.border.relief.outset?.should be_true
    st.border.relief_style.shade?.should be_true
    st.border.any?.should be_true # materialized a visible frame
    st.look = :beveled
    st.border.relief_style.weight?.should be_true
    st.look = :floating
    st.shadow.auto_sides?.should be_true
    st.shadow.ratio.should eq 0.5
    st.look = :flat
    st.border.relief.none?.should be_true
  end
end

describe "borders CSS (axes)" do
  it "parses multi-token border-style across the axes" do
    st = Style.new
    p = Crysterm::CSS::Properties
    p.apply st, "border-style", "dotted braille inner"
    b = st.border
    b.type.medium.braille?.should be_true
    b.pattern.dotted?.should be_true
    b.align.inner?.should be_true
    # Single tokens keep the legacy preset semantics.
    p.apply st, "border-style", "dotted"
    st.border.type.should eq BorderType::Dotted
    st.border.type.medium.line?.should be_true
  end

  it "gives a multi-token type its natural alignment unless one is named" do
    st = Style.new
    p = Crysterm::CSS::Properties
    p.apply st, "border-style", "dotted braille"
    st.border.align.outer?.should be_true
  end

  it "parses the border shorthand with axis tokens" do
    st = Style.new
    Crysterm::CSS::Properties.apply st, "border", "dotted braille inner #ff0000"
    b = st.border
    b.type.medium.braille?.should be_true
    b.pattern.dotted?.should be_true
    b.align.inner?.should be_true
    b.fg.should eq 0xff0000
    b.top.should eq 1 # the shorthand's default 1-cell box
  end

  it "parses border-align, border-corner-ratio and per-corner border-radius" do
    st = Style.new
    p = Crysterm::CSS::Properties
    p.apply st, "border", "outer"
    p.apply st, "border-align", "inner"
    st.border.align.inner?.should be_true
    p.apply st, "border-corner-ratio", "half"
    st.border.corner_ratio.should eq 0.5
    p.apply st, "border-corner-ratio", "none"
    st.border.corner_ratio.should be_nil
    p.apply st, "border", "solid"
    p.apply st, "border-radius", "8px 8px 0 0" # the tab shape (tl tr br bl)
    c = st.border.corners
    c.tl.rounded?.should be_true
    c.tr.rounded?.should be_true
    c.br.square?.should be_true
    c.bl.square?.should be_true
    c.radii[0].should eq 8
    p.apply st, "border-bottom-left-radius", "4px"
    st.border.corners.bl.rounded?.should be_true
  end

  it "parses light, look and relief-style" do
    st = Style.new
    p = Crysterm::CSS::Properties
    p.apply st, "light", "n spot"
    st.light.should eq Light.new(Light::Direction::N, Light::Kind::Spot)
    p.apply st, "light", "se"
    st.light.should eq Light.new(Light::Direction::SE)
    p.apply st, "light", "none"
    st.light.should be_nil
    p.apply st, "look", "beveled"
    st.look.should eq Style::Look::Beveled
    st.border.relief_style.weight?.should be_true
    p.apply st, "relief-style", "shade"
    st.border.relief_style.shade?.should be_true
  end
end

describe "Widget::Line stroke axes" do
  it "derives the separator rule from type/pattern/ratio" do
    with_aspect do
      s = headless_screen(10, 6)
      s.glyph_tier = Glyphs::Tier::Extended
      Widget::Line.new(parent: s).style.fill_char.should eq '─' # unchanged default
      Widget::Line.new(parent: s, pattern: :dotted).style.fill_char.should eq '┈'
      Widget::Line.new(parent: s, ratio: :full).style.fill_char.should eq '━'
      Widget::Line.new(parent: s, pattern: :dotted, ratio: :full).style.fill_char.should eq '┉'
      Widget::Line.new(parent: s, pattern: :double).style.fill_char.should eq '═'
      Widget::Line.new(parent: s, type: :block, ratio: :full).style.fill_char.should eq '▄'
      Widget::Line.new(parent: s, type: :braille).style.fill_char.should eq '⠒' # centered dot-row
      Widget::Line.new(parent: s, type: :braille, pattern: :dotted).style.fill_char.should eq '⠂'
    end
  end

  it "re-derives on orientation change, pinning an explicit char" do
    with_aspect do
      s = headless_screen(10, 6)
      s.glyph_tier = Glyphs::Tier::Extended
      l = Widget::Line.new(parent: s, pattern: :dotted)
      l.orientation = Tput::Orientation::Vertical
      l.style.fill_char.should eq '┊'
      pinned = Widget::Line.new(parent: s, char: '=')
      pinned.orientation = Tput::Orientation::Vertical
      pinned.style.fill_char.should eq '='
    end
  end

  it "degrades a braille separator below the Extended tier" do
    with_aspect do
      s = headless_screen(10, 6)
      s.glyph_tier = Glyphs::Tier::Unicode
      Widget::Line.new(parent: s, type: :braille).style.fill_char.should eq '┈'
      Widget::Line.new(parent: s, type: :braille, pattern: :dashed).style.fill_char.should eq '┄'
    end
  end
end

describe "Window#light" do
  it "defaults to NW directional and feeds widgets without an override" do
    s = headless_screen(8, 5)
    s.light.should eq Light::DEFAULT
    s.alloc
    b = Widget::Box.new(left: 0, top: 0, width: 6, height: 3, content: "")
    s << b
    b.effective_light.should eq Light::DEFAULT
    s.light = :se
    b.effective_light.direction.se?.should be_true
    b.style.light = :n
    b.effective_light.direction.n?.should be_true
  end
end
