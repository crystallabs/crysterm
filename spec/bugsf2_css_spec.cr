require "./spec_helper"

include Crysterm

# Regression specs for the BUGS-F2 CSS findings (5, 22, 25, 49, 50, 51).

private def headless_screen(width = 80, height = 24)
  Crysterm::Window.new(
    default_quit_keys: false,
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

# Runs *block* with the global default (user-agent) stylesheet emptied, then
# restores it, so asserting on computed colors isn't foiled by the theme (which
# would otherwise materialize extra base colors/state styles).
private def without_default_theme(&)
  saved = Crysterm::CSS.default_stylesheet
  Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
  begin
    yield
  ensure
    Crysterm::CSS.default_stylesheet = saved
  end
end

private def rgb(name)
  Crysterm::Colors.convert(name).to_i32
end

# --- Finding 5: sub-element state rule must not strip the parent's base rules -

describe "BUGS-F2 #5 sub-element state rule keeps the parent's base rules" do
  it "keeps the base background/color in a state materialized by a sub-element :hover" do
    screen = headless_screen
    bar = Widget::ProgressBar.new parent: screen

    without_default_theme do
      screen.stylesheet = <<-CSS
        ProgressBar { background-color: blue; color: white; }
        ProgressBar::indicator:hover { color: red; }
        CSS
      screen.apply_stylesheet

      # The Hovered state is materialized because a sub-element rule targets it.
      # It must still carry the parent's base declarations, not flash to the
      # pristine pre-CSS look.
      bar.styles.hovered.bg.should eq rgb("blue")
      bar.styles.hovered.fg.should eq rgb("white")
      # And the sub-element hover rule still applied.
      bar.styles.hovered.indicator.fg.should eq rgb("red")
      # Normal state unaffected.
      bar.styles.normal.bg.should eq rgb("blue")
    end
  end

  it "keeps the base background when a sub-element :focus rule materializes focus" do
    screen = headless_screen
    bar = Widget::ProgressBar.new parent: screen

    without_default_theme do
      screen.stylesheet = <<-CSS
        ProgressBar { background-color: navy; }
        ProgressBar::indicator:focus { color: yellow; }
        CSS
      screen.apply_stylesheet

      bar.styles.focused.bg.should eq rgb("navy")
      bar.styles.focused.indicator.fg.should eq rgb("yellow")
    end
  end
end

# --- Finding 22: no-rules early exit must not wipe structural invalidation ----

describe "BUGS-F2 #22 no-rules early exit preserves structural invalidation" do
  it "styles a widget added during an unstyled period once a sheet is reassigned" do
    screen = headless_screen
    a = Widget::Button.new parent: screen

    without_default_theme do
      screen.stylesheet = "Button { color: red; }"
      screen.apply_stylesheet
      a.styles.normal.fg.should eq rgb("red") # A styled, document cached

      # Unstyled period: drop the sheet (no rules anywhere), then add B — a
      # structural change that must survive the no-rules early exits.
      screen.stylesheet = nil
      screen.apply_stylesheet # no-rules early exit
      b = Widget::Button.new parent: screen
      screen.apply_stylesheet # another no-rules early exit

      # Reassign an active sheet: the cascade must re-parse against the current
      # tree (B included), not skip B against a stale cached document.
      screen.stylesheet = "Button { color: green; }"
      screen.apply_stylesheet

      a.styles.normal.fg.should eq rgb("green")
      b.styles.normal.fg.should eq rgb("green")
    end
  end
end

# --- Finding 25: Row positional selectors + direct Row {} declarations --------

describe "BUGS-F2 #25 table Row selectors" do
  it "applies a direct Row rule to every cell of every row" do
    screen = headless_screen
    table = Widget::Table.new parent: screen, rows: [["A", "B"], ["1", "2"], ["3", "4"]]

    without_default_theme do
      screen.stylesheet = "Row { background-color: navy; }"
      screen.apply_stylesheet

      table.css_cell_style(0, 0).not_nil!.bg.should eq rgb("navy")
      table.css_cell_style(1, 1).not_nil!.bg.should eq rgb("navy")
      table.css_cell_style(2, 0).not_nil!.bg.should eq rgb("navy")
    end
  end

  it "targets a single row by :nth-child position (rows emitted before sub-elements)" do
    screen = headless_screen
    table = Widget::Table.new parent: screen, rows: [["A", "B"], ["1", "2"], ["3", "4"]]

    without_default_theme do
      screen.stylesheet = "Row:nth-child(2) Cell { color: red; }"
      screen.apply_stylesheet

      # nth-child(2) is the 2nd Row == data row index 1, cleanly, regardless of
      # any scrollbar/label sub-element nodes.
      table.css_cell_style(1, 0).not_nil!.fg.should eq rgb("red")
      table.css_cell_style(1, 1).not_nil!.fg.should eq rgb("red")
      table.css_cell_style(0, 0).try(&.fg).should_not eq rgb("red")
      table.css_cell_style(2, 0).try(&.fg).should_not eq rgb("red")
    end
  end

  it "layers a Cell rule on top of a Row rule (row is the base, cell wins)" do
    screen = headless_screen
    table = Widget::Table.new parent: screen, rows: [["A", "B"], ["1", "2"], ["3", "4"]]

    without_default_theme do
      screen.stylesheet = <<-CSS
        Row { background-color: navy; color: white; }
        Cell:nth-child(1) { color: yellow; }
        CSS
      screen.apply_stylesheet

      # First-column cell: navy background inherited from the Row rule, yellow
      # text from the more-specific Cell rule.
      c10 = table.css_cell_style(1, 0).not_nil!
      c10.bg.should eq rgb("navy")
      c10.fg.should eq rgb("yellow")
      # Other-column cell keeps the row's white text.
      table.css_cell_style(1, 1).not_nil!.fg.should eq rgb("white")
    end
  end
end

# --- Finding 49: border named widths (thin/medium/thick) ----------------------

describe "BUGS-F2 #49 border named widths" do
  it "resolves the border-width shorthand named widths" do
    thin = Style.new
    Crysterm::CSS::Properties.apply(thin, "border-width", "thin")
    thin.border.top.should eq 1
    thin.border.left.should eq 1

    medium = Style.new
    Crysterm::CSS::Properties.apply(medium, "border-width", "medium")
    medium.border.right.should eq 1

    thick = Style.new
    Crysterm::CSS::Properties.apply(thick, "border-width", "thick")
    thick.border.top.should eq 2
    thick.border.bottom.should eq 2
    thick.border.left.should eq 2
  end

  it "resolves a per-side border-*-width named width" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-width", "thick")
    s.border.top.should eq 2
  end

  it "reads a named width in the border shorthand as width, not color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "thin solid red")
    s.border.left.should eq 1
    s.border.top.should eq 1
    s.border.type.should eq BorderType::Solid
    # The real color is still parsed; the width keyword did not poison it.
    s.border.fg.should eq rgb("red")
  end

  it "sizes the whole border from a lone named width in the shorthand" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "thick")
    s.border.left.should eq 2
    s.border.top.should eq 2
  end
end

# --- Finding 50: @media `not` / media-type handling ---------------------------

describe "BUGS-F2 #50 @media not / media-type conjunction" do
  colors = 0x1000000

  it "makes `not (...)` unmatchable rather than applying the un-negated feature" do
    mq = Crysterm::CSS::MediaQuery.parse("not (min-width: 10)")
    mq.matchable?.should be_false
    mq.matches?(80, 24, colors).should be_false
    mq.matches?(5, 24, colors).should be_false
  end

  it "does not match an unsupported media type AND-ed with a feature" do
    mq = Crysterm::CSS::MediaQuery.parse("print and (min-width: 10)")
    mq.matches?(80, 24, colors).should be_false
  end

  it "honors a supported media type AND-ed with a feature" do
    mq = Crysterm::CSS::MediaQuery.parse("screen and (min-width: 10)")
    mq.matches?(80, 24, colors).should be_true
    mq.matches?(5, 24, colors).should be_false
  end

  it "still evaluates a plain feature query (no regression)" do
    mq = Crysterm::CSS::MediaQuery.parse("(max-width: 40)")
    mq.matches?(30, 24, colors).should be_true
    mq.matches?(50, 24, colors).should be_false
  end
end

# --- Finding 51: !important on a custom property must not poison var() ---------

describe "BUGS-F2 #51 !important on a custom property" do
  it "strips the !important marker from the stored custom-property value" do
    sheet = Crysterm::CSS::Stylesheet.parse <<-CSS
      Button { --accent: red !important; color: var(--accent); }
      CSS
    sheet.variables["--accent"].should eq "red"
  end

  it "resolves a var() consumer to the clean color, not `red !important`" do
    screen = headless_screen
    button = Widget::Button.new parent: screen

    without_default_theme do
      screen.stylesheet = <<-CSS
        Button { --accent: red !important; color: var(--accent); }
        CSS
      screen.apply_stylesheet

      button.styles.normal.fg.should eq rgb("red")
    end
  end
end
