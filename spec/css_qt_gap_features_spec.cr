require "./spec_helper"

include Crysterm

# Three QT-CSS-GAP-NOTES additions driven end-to-end through the CSS pipeline:
#   * `text-decoration: line-through` -> `Style#strike` (SGR 9),
#   * the `dashed`/`dotted`/`double` `border-style` keywords (new `BorderType`s
#     with their own box-drawing glyph sets),
#   * `lineedit-password-character` (Qt) -> `LineEdit#password_character`.

private def render_screen
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def screen_has_char?(screen, char : Char) : Bool
  (0...screen.height).any? do |y|
    next false unless screen.lines[y]?
    (0...screen.width).any? { |x| screen.lines[y][x].char == char }
  end
end

# Applies *css* to a fresh headless `Box` and returns its computed normal style.
private def box_normal_style(css : String) : Style
  screen = headless_screen
  box = Widget::Box.new parent: screen
  screen.stylesheet = css
  screen.apply_stylesheet
  box.styles.normal
end

# Renders one bordered `Box` styled by *css* and returns the screen so callers
# can inspect which border glyphs were painted.
private def render_bordered_box(css : String)
  screen = render_screen
  Widget::Box.new parent: screen, top: 0, left: 0, width: 10, height: 5
  screen.stylesheet = css
  screen._render
  screen
end

describe "text-decoration: line-through" do
  it "maps line-through onto Style#strike" do
    box_normal_style("Box { text-decoration: line-through; }").strike?.should be_true
  end

  it "combines line-through with the other decorations" do
    style = box_normal_style("Box { text-decoration: underline line-through; }")
    style.underline?.should be_true
    style.strike?.should be_true
  end

  it "is shorthand: an absent line-through clears strike" do
    screen = headless_screen
    box = Widget::Box.new parent: screen
    box.styles.normal.strike = true
    screen.stylesheet = "Box { text-decoration: underline; }"
    screen.apply_stylesheet

    box.styles.normal.strike?.should be_false
  end
end

describe "border-style keywords" do
  it "maps dashed/dotted/double onto the BorderType" do
    {"dashed" => BorderType::Dashed,
     "dotted" => BorderType::Dotted,
     "double" => BorderType::Double}.each do |keyword, type|
      box_normal_style("Box { border-style: #{keyword}; }").border.type.should eq type
    end
  end

  it "accepts the keyword in the `border` shorthand and enables the sides" do
    border = box_normal_style("Box { border: double; }").border
    border.type.should eq BorderType::Double
    border.any?.should be_true
  end

  it "renders a dashed border with the dashed glyphs" do
    screen = render_bordered_box("Box { border-style: dashed; }")
    # Light dashed runs: `┄` horizontal, `┆` vertical.
    screen_has_char?(screen, '┄').should be_true
    screen_has_char?(screen, '┆').should be_true
  end

  it "renders a double border with the double glyphs" do
    screen = render_bordered_box("Box { border-style: double; }")
    screen_has_char?(screen, '═').should be_true # horizontal run
    screen_has_char?(screen, '║').should be_true # vertical run
    screen_has_char?(screen, '╔').should be_true # a corner
  end

  it "keeps the solid Line glyphs for `solid`/`line`" do
    screen = render_bordered_box("Box { border-style: solid; }")
    screen_has_char?(screen, '─').should be_true
    screen_has_char?(screen, '┄').should be_false
    screen_has_char?(screen, '═').should be_false
  end
end

describe "BorderType glyph helpers" do
  it "treats every line type as line_family and Bg as not" do
    BorderType::Line.line_family?.should be_true
    BorderType::Dashed.line_family?.should be_true
    BorderType::Dotted.line_family?.should be_true
    BorderType::Double.line_family?.should be_true
    BorderType::Bg.line_family?.should be_false
  end

  it "returns a distinct glyph set per type" do
    BorderType::Line.line_glyphs[:h].should eq '─'
    BorderType::Dashed.line_glyphs[:h].should eq '┄'
    BorderType::Dotted.line_glyphs[:h].should eq '┈'
    BorderType::Double.line_glyphs[:v].should eq '║'
    BorderType::Double.line_glyphs[:tl].should eq '╔'
  end
end

describe "lineedit-password-character" do
  it "is a geometry property" do
    Crysterm::CSS::Geometry.handles?("lineedit-password-character").should be_true
  end

  it "sets the mask char from a numeric Unicode code point (Qt style)" do
    screen = headless_screen
    input = Widget::LineEdit.new parent: screen
    screen.stylesheet = "LineEdit { lineedit-password-character: 9679; }"
    screen.apply_stylesheet

    input.password_character.should eq '●'
  end

  it "sets the mask char from a literal value" do
    screen = headless_screen
    input = Widget::LineEdit.new parent: screen
    screen.stylesheet = "LineEdit { lineedit-password-character: #; }"
    screen.apply_stylesheet

    input.password_character.should eq '#'
  end

  it "masks the displayed value with the custom char when censored" do
    screen = headless_screen
    input = Widget::LineEdit.new parent: screen, censor: true
    input.password_character = '#'
    input.value = "abc"

    input.content.should eq "###"
  end

  it "defaults the mask char to *" do
    input = Widget::LineEdit.new censor: true
    input.password_character.should eq '*'
  end

  it "is a no-op on a non-LineEdit widget (does not raise)" do
    screen = headless_screen
    Widget::Box.new parent: screen
    screen.stylesheet = "Box { lineedit-password-character: 9679; }"
    screen.apply_stylesheet # should simply ignore it
  end
end
