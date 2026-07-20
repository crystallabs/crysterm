require "./spec_helper"

include Crysterm

# GLYPHS.md phase 3: per-position border char overrides + their CSS spellings
# (`border-chars`, `border-top-left-char` …), the `shadow-char-*` family, and
# the `@media (glyphs: …)` feature over the support-tier ordering.

private def gmb_screen(width = 40, height = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

private def gmb_ch(s, y, x)
  s.lines[y][x].char
end

describe "border-chars CSS (rounded corners)" do
  it "draws rounded corners via the per-corner longhands" do
    s = gmb_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5
    s.stylesheet = <<-CSS
      Box { border: solid;
            border-top-left-char: "╭"; border-top-right-char: "╮";
            border-bottom-left-char: "╰"; border-bottom-right-char: "╯"; }
      CSS
    s.apply_stylesheet
    s.repaint
    gmb_ch(s, box.atop, box.aleft).should eq '╭'
    gmb_ch(s, box.atop, box.aleft + 9).should eq '╮'
    gmb_ch(s, box.atop + 4, box.aleft).should eq '╰'
    gmb_ch(s, box.atop + 4, box.aleft + 9).should eq '╯'
    # Runs keep the registry family glyphs.
    gmb_ch(s, box.atop, box.aleft + 4).should eq '─'
    gmb_ch(s, box.atop + 2, box.aleft).should eq '│'
  end

  it "applies the six-value border-chars shorthand" do
    s = gmb_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5
    s.stylesheet = %(Box { border: solid; border-chars: "1" "2" "3" "4" "h" "v"; })
    s.apply_stylesheet
    s.repaint
    gmb_ch(s, box.atop, box.aleft).should eq '1'
    gmb_ch(s, box.atop, box.aleft + 9).should eq '2'
    gmb_ch(s, box.atop + 4, box.aleft).should eq '3'
    gmb_ch(s, box.atop + 4, box.aleft + 9).should eq '4'
    gmb_ch(s, box.atop, box.aleft + 4).should eq 'h'
    gmb_ch(s, box.atop + 2, box.aleft).should eq 'v'
  end

  it "applies the three-value (corner h v) shorthand and none clears back" do
    s = gmb_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5
    s.stylesheet = <<-CSS
      Box { border: solid; border-chars: "+" "-" "|"; }
      Box { border-top-left-char: none; }
      CSS
    s.apply_stylesheet
    s.repaint
    # `none` cleared the TL position override; the corner *group* still holds.
    gmb_ch(s, box.atop, box.aleft).should eq '+'
    gmb_ch(s, box.atop, box.aleft + 9).should eq '+'
    gmb_ch(s, box.atop, box.aleft + 4).should eq '-'
    gmb_ch(s, box.atop + 2, box.aleft).should eq '|'
  end

  it "drops a wide char on a border position (cells are one column)" do
    st = Style.new
    Crysterm::CSS::Properties.apply st, "border", "solid"
    Crysterm::CSS::Properties.apply st, "border-top-left-char", %("🚀")
    st.border.chars?.should be_false # the wide glyph never installed an override
  end

  it "honors position chars on a Fill border too" do
    b = Border.new BorderType::Fill
    b.fill_char = '#'
    b.top_left_char = '@'
    b.top_left_char.should eq '@'
    b.top_right_char.should eq '#' # falls to fill_char through the group
  end
end

describe "BorderType::Rounded" do
  it "draws arc corners with light runs, and collapses to + - | at tier Ascii" do
    g = BorderType::Rounded.line_glyphs
    {g[:tl], g[:tr], g[:bl], g[:br], g[:h], g[:v]}.should eq({'╭', '╮', '╰', '╯', '─', '│'})
    a = BorderType::Rounded.line_glyphs(Glyphs::Tier::Ascii)
    {a[:tl], a[:tr], a[:bl], a[:br], a[:h], a[:v]}.should eq({'+', '+', '+', '+', '-', '|'})
  end

  it "is selected by the border-style keyword `rounded`" do
    s = gmb_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5
    s.stylesheet = %(Box { border: rounded; })
    s.apply_stylesheet
    s.repaint
    gmb_ch(s, box.atop, box.aleft).should eq '╭'
    gmb_ch(s, box.atop + 4, box.aleft + 9).should eq '╯'
    gmb_ch(s, box.atop, box.aleft + 4).should eq '─'
  end

  it "maps a positive border-radius onto rounded corners (Qt themes)" do
    s = gmb_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 5
    s.stylesheet = %(Box { border: solid red; border-radius: 4px; })
    s.apply_stylesheet
    s.repaint
    gmb_ch(s, box.atop, box.aleft).should eq '╭'
    gmb_ch(s, box.atop + 4, box.aleft).should eq '╰'
  end

  it "squares back on radius 0 and leaves stronger families alone" do
    st = Style.new
    p = Crysterm::CSS::Properties
    p.apply st, "border", "solid"
    p.apply st, "border-radius", "0.5em"
    st.border.type.rounded?.should be_true
    p.apply st, "border-radius", "0"
    st.border.type.solid?.should be_true

    p.apply st, "border", "double"
    p.apply st, "border-radius", "4px"
    st.border.type.double?.should be_true # a Double border stays double
  end
end

describe "shadow-char-* CSS" do
  it "sets the axis groups and per-corner overrides" do
    st = Style.new
    p = Crysterm::CSS::Properties
    p.apply st, "shadow-char-horizontal", %("▀")
    p.apply st, "shadow-char-vertical", %("▌")
    p.apply st, "shadow-char-bottom-right", %("▘")
    st.shadow.horizontal_char.should eq '▀'
    st.shadow.left_char.should eq '▌' # side falls back to the axis group
    st.shadow.bottom_right_char.should eq '▘'
    st.shadow.top_left_char.should eq '▀' # corner falls to diagonal→horizontal
    st.shadow.glyphs?.should be_true
  end

  it "clears a glyph with none and drops a wide char" do
    st = Style.new
    p = Crysterm::CSS::Properties
    p.apply st, "shadow-char-horizontal", %("▀")
    p.apply st, "shadow-char-horizontal", "none"
    st.shadow.glyphs?.should be_false
    p.apply st, "shadow-char-vertical", %("🚀")
    st.shadow.glyphs?.should be_false
  end
end

describe "@media (glyphs: …)" do
  it "parses tier keywords and matches over the ordering" do
    mq = Crysterm::CSS::MediaQuery.parse("(glyphs: ascii)")
    mq.matches?(80, 24, 256, 0).should be_true
    mq.matches?(80, 24, 256, 1).should be_false

    mq = Crysterm::CSS::MediaQuery.parse("(min-glyphs: extended)")
    mq.matches?(80, 24, 256, 2).should be_true
    mq.matches?(80, 24, 256, 1).should be_false

    mq = Crysterm::CSS::MediaQuery.parse("(max-glyphs: unicode)")
    mq.matches?(80, 24, 256, 0).should be_true
    mq.matches?(80, 24, 256, 2).should be_false
  end

  it "defaults to tier Unicode when unspecified and composes with AND" do
    mq = Crysterm::CSS::MediaQuery.parse("(min-glyphs: unicode) and (min-width: 40)")
    mq.matches?(80, 24, 256).should be_true
    mq.matches?(20, 24, 256).should be_false
  end

  it "treats an unknown tier keyword as unmatchable" do
    mq = Crysterm::CSS::MediaQuery.parse("(glyphs: nerdfont)")
    mq.matchable?.should be_false
  end

  it "applies tier-conditional rules and recascades on a tier switch" do
    s = gmb_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    s.stylesheet = <<-CSS
      Box { background-color: blue; }
      @media (glyphs: ascii) {
        Box { background-color: red; }
      }
      CSS
    blue = Crysterm::Colors.convert("blue").to_i32
    red = Crysterm::Colors.convert("red").to_i32
    s.apply_stylesheet
    s.repaint
    box.styles.normal.bg.should eq blue # default tier Unicode: guarded rule off

    s.glyph_tier = Glyphs::Tier::Ascii
    s.repaint # recascades via the has_media?/tier-change path
    box.styles.normal.bg.should eq red

    s.glyph_tier = Glyphs::Tier::Unicode
    s.repaint
    box.styles.normal.bg.should eq blue
  end
end
