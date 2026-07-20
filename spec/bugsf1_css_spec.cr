require "./spec_helper"
require "file_utils"

include Crysterm

# Regression specs for the BUGS-F1 CSS findings (21, 22, 23, 42, 45, 46, 47, 48).

private def headless_screen(width = 80, height = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

# Runs *block* with the global default (user-agent) stylesheet emptied, then
# restores it, so asserting on computed colors isn't foiled by the theme.
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

# --- Finding 45: per-side padding/margin longhands drop invalid values --------

describe "BUGS-F1 #45 per-side padding/margin longhands drop invalid/blank values" do
  it "keeps a previously-set padding-left when a blank value arrives (collapsed var)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding-left", "3")
    Crysterm::CSS::Properties.apply(s, "padding-left", "") # undefined var() collapses to ""
    s.padding.left.should eq 3
    Crysterm::CSS::Properties.apply(s, "padding-left", "   ")
    s.padding.left.should eq 3
  end

  it "keeps a previously-set padding-top when an unparseable length arrives" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding-top", "2")
    Crysterm::CSS::Properties.apply(s, "padding-top", "3cm") # unmapped unit -> not a cell count
    s.padding.top.should eq 2
  end

  it "keeps a previously-set margin-right/bottom on a blank value" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "margin-right", "4")
    Crysterm::CSS::Properties.apply(s, "margin-bottom", "5")
    Crysterm::CSS::Properties.apply(s, "margin-right", "")
    Crysterm::CSS::Properties.apply(s, "margin-bottom", "")
    s.margin.right.should eq 4
    s.margin.bottom.should eq 5
  end

  it "still applies a valid per-side value (no regression)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding-left", "6")
    s.padding.left.should eq 6
    Crysterm::CSS::Properties.apply(s, "padding-left", "0") # explicit 0 still applies
    s.padding.left.should eq 0
  end
end

# --- Finding 46: nested @import resolves against the importing file's dir ------

describe "BUGS-F1 #46 nested @import resolves relative to the importing file" do
  it "reads a deeply-imported file relative to its importer, not the top-level base" do
    root = File.tempname("crysterm_f46")
    Dir.mkdir_p File.join(root, "sub")
    File.write File.join(root, "main.css"), %(@import "sub/a.css";\nBox { color: white; }\n)
    File.write File.join(root, "sub", "a.css"), %(@import "b.css";\n)
    File.write File.join(root, "sub", "b.css"), %(Deep { color: red; }\n)

    sheet = Crysterm::CSS::Stylesheet.from_file File.join(root, "main.css")

    # The nested `@import "b.css"` inside sub/a.css must resolve to sub/b.css.
    sheet.warnings.should be_empty
    sheet.rules.any? { |r| r.declarations["color"]? == "red" }.should be_true   # from sub/b.css
    sheet.rules.any? { |r| r.declarations["color"]? == "white" }.should be_true # from main.css
  ensure
    root.try { |r| FileUtils.rm_rf r }
  end
end

# --- Finding 47: parent declarations sort before nested rules on a tie --------

describe "BUGS-F1 #47 nested rule wins an equal-specificity tie over the parent declaration" do
  it "lets a nested @media override the parent declaration on a wide terminal" do
    screen = headless_screen(80, 24)
    box = Widget::Box.new parent: screen

    without_default_theme do
      screen.stylesheet = "Box { color: red; @media (min-width: 10) { color: blue; } }"
      screen.apply_stylesheet
      box.styles.normal.fg.should eq rgb("blue") # nested media rule wins the tie
    end
  end

  it "lets a nested `&` block override the parent declaration on a tie" do
    screen = headless_screen(80, 24)
    box = Widget::Box.new parent: screen

    without_default_theme do
      screen.stylesheet = "Box { color: red; & { color: blue; } }"
      screen.apply_stylesheet
      box.styles.normal.fg.should eq rgb("blue")
    end
  end
end

# --- Finding 22: state pseudo-classes inside :has() are lowered ---------------

describe "BUGS-F1 #22 state pseudo-classes inside :has() are lowered to .state-*" do
  it "lowers a `:focus` inside `:has(...)` in the parsed rule" do
    sheet = Crysterm::CSS::Stylesheet.parse "Form:has(Input:focus) { color: green; }"
    rule = sheet.rules.first
    inner = rule.has.not_nil!
    inner.should contain "state-focused"
    inner.should_not contain ":focus"
  end

  it "marks the sheet dynamic-state when the state lives only inside :has()" do
    sheet = Crysterm::CSS::Stylesheet.parse "Form:has(Input:focus) { color: green; }"
    sheet.dynamic_state?.should be_true
  end

  it "matches Form:has(Input:focus) once the input is focused (end-to-end)" do
    screen = headless_screen
    form = Widget::Form.new
    input = Widget::Input.new
    form.append input
    screen.append form

    without_default_theme do
      screen.stylesheet = <<-CSS
        Form { color: white; }
        Form:has(Input:focus) { color: green; }
      CSS
      screen.apply_stylesheet
      form.styles.normal.fg.should eq rgb("white") # nothing focused

      input.state = WidgetState::Focused
      screen.apply_stylesheet
      form.styles.normal.fg.should eq rgb("green") # :has(Input:focus) now matches

      input.state = WidgetState::Normal
      screen.apply_stylesheet
      form.styles.normal.fg.should eq rgb("white") # reverts
    end
  end
end

# --- Finding 23: scoped restyle falls back to full recompute with :has() ------

describe "BUGS-F1 #23 an attribute change updates a :has() ancestor subject outside its subtree" do
  it "restyles a Form matched by Form:has(.error) when a deep descendant gains .error" do
    screen = headless_screen
    form = Widget::Form.new
    mid = Widget::Box.new # intermediate ancestor, so the input's parent subtree excludes the form
    deep = Widget::Box.new
    mid.append deep
    form.append mid
    screen.append form

    without_default_theme do
      screen.stylesheet = <<-CSS
        Form { color: white; }
        Form:has(.error) { color: green; }
      CSS
      screen.apply_stylesheet
      form.styles.normal.fg.should eq rgb("white")

      # Dirties only `deep`'s parent (`mid`) subtree — the Form (the :has subject)
      # is an ancestor outside that scope; the relational fallback recomputes all.
      deep.add_css_class "error"
      screen.apply_stylesheet
      form.styles.normal.fg.should eq rgb("green")
    end
  end
end

# --- Finding 21: @media re-evaluated after a terminal resize ------------------

describe "BUGS-F1 #21 @media queries are re-evaluated after a terminal resize" do
  it "re-applies a media rule when the size folds into the cascade-skip identity" do
    screen = headless_screen(100, 24)
    box = Widget::Box.new parent: screen

    without_default_theme do
      screen.stylesheet = <<-CSS
        Box { color: white; }
        @media (max-width: 40) { Box { color: green; } }
      CSS
      screen.apply_stylesheet
      box.styles.normal.fg.should eq rgb("white") # 100 > 40, media skipped

      screen.width = 40
      screen.apply_stylesheet                     # was: early-returned on identical document
      box.styles.normal.fg.should eq rgb("green") # narrow: media now applies
    end
  end

  it "re-evaluates @media through the render path after a resize (end-to-end)" do
    screen = headless_screen(100, 24)
    box = Widget::Box.new parent: screen, top: 0, left: 0, width: 10, height: 3

    begin
      without_default_theme do
        screen.stylesheet = <<-CSS
          Box { color: white; }
          @media (max-width: 40) { Box { color: green; } }
        CSS
        screen.repaint
        box.styles.normal.fg.should eq rgb("white")

        # Mirror the resize path (resize; realloc; render) — nothing marks CSS
        # dirty, so this exercises the media-size-change trigger in `repaint`.
        screen.width = 40
        screen.realloc
        screen.repaint
        box.styles.normal.fg.should eq rgb("green")

        screen.width = 100
        screen.realloc
        screen.repaint
        box.styles.normal.fg.should eq rgb("white")
      end
    ensure
      screen.destroy
    end
  end
end

# --- Finding 42: swapping to a missing @keyframes stops the old animation -----

describe "BUGS-F1 #42 swapping animation: to a missing @keyframes stops the old clock" do
  it "freezes the old animation instead of ticking it forever" do
    screen = headless_screen(20, 5)
    box = Widget::Box.new parent: screen, top: 0, left: 0, width: 10, height: 3

    begin
      # Start a valid, looping animation via a real render (so the driving
      # `FrameClock`'s `request_render` works). One `repaint` is enough; the
      # clock then ticks on its own during the sleeps below.
      screen.stylesheet = "@keyframes good { from { opacity: 0.2; } to { opacity: 1.0; } } .a { animation: good 0.05s linear infinite; }"
      box.add_css_class "a"
      screen.repaint
      sleep 0.02.seconds

      # Swap `animation:` to a name with no `@keyframes`, mutating the already-
      # cascaded style in place (no re-cascade, so the animated `Style` object
      # stays the same and a leaked clock stays observable). The old clock must
      # be stopped now; before the fix its early return left it ticking forever.
      Crysterm::CSS::Properties.apply(box.style, "animation", "missing 0.05s linear infinite")
      box.ensure_css_animation

      frozen = box.style.opacity
      samples = [] of Float64?
      6.times do
        sleep 0.02.seconds
        box.ensure_css_animation # a re-render must not restart the failed lookup either
        samples << box.style.opacity
      end
      samples.all? { |a| a == frozen }.should be_true # alpha frozen: old clock stopped
    ensure
      screen.destroy
    end
  end
end

# --- Finding 48: state rules on table-cell extra slots ------------------------

describe "BUGS-F1 #48 state-specific rules on table-cell extra slots" do
  it "applies the base Cell rule deterministically and drops Cell:hover" do
    screen = headless_screen
    table = Widget::Table.new parent: screen, rows: [["A", "B"], ["1", "2"]]

    without_default_theme do
      screen.stylesheet = <<-CSS
        Cell { color: white; }
        Cell:hover { color: red; }
      CSS
      screen.apply_stylesheet

      # State-independent per-cell storage can't represent :hover, so the base
      # (Normal) rule wins deterministically rather than being clobbered by it.
      table.css_cell_style(1, 0).not_nil!.fg.should eq rgb("white")
      table.css_cell_style(1, 1).not_nil!.fg.should eq rgb("white")
    end
  end

  it "does not let a lone Cell:hover rule apply in every state" do
    screen = headless_screen
    table = Widget::Table.new parent: screen, rows: [["A", "B"], ["1", "2"]]

    without_default_theme do
      screen.stylesheet = "Cell:hover { color: red; }"
      screen.apply_stylesheet

      # No base Cell rule -> nothing folds into Normal -> the hover style must not
      # leak into the always-visible cell appearance.
      cell = table.css_cell_style(1, 1)
      (cell.nil? || cell.fg != rgb("red")).should be_true
    end
  end
end
