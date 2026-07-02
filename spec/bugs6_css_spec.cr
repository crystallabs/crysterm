require "./spec_helper"

include Crysterm

# Regression specs for the BUGS6 "CSS Engine Internals" fixes (BUGS6 §8):
#
#  1. `Widget#to_html` trailed each widget's real children with its
#     sub-element/extra pseudo-nodes (`<w-scrollbar>`, `<w-item>`, a `Menu`'s
#     `<w-separator>`, a `Table`'s `<w-cell>`, ...). A non-widget pseudo-node
#     therefore occupied the last-child slot, breaking every backward/only
#     structural pseudo-class (`:last-child`, `:nth-last-child`, `:only-child`,
#     `:last-of-type`) on the real children — e.g. `List Box:last-child` matched
#     nothing. The cascade now matches such rules against a *structural*
#     document that omits the pseudo-nodes (see `Widget#to_html(structural:)`),
#     while slot/extra nodes still match against the full document.
#
#  2. `MediaQuery` folded feature names case-sensitively and treated a query that
#     parsed zero conditions from a non-empty prelude as vacuously true
#     (`[].all?`), so `@media (Min-Width: 80)`, `@media print` and
#     `@media (prefers-color-scheme: dark)` matched *every* terminal, and
#     `@media (min-width: 80) and (orientation: portrait)` over-matched on width
#     alone. Feature names now fold case-insensitively, and a non-empty query
#     with no recognizable numeric feature (or any unknown feature) is
#     unmatchable.
#
#  3. The selector post-processing depth scanners (`split_subject`,
#     `top_level_pseudo_index`, `compound_end_index`, `matching_paren`,
#     `peel_has`/`strip_has`, `top_level_comma`) counted `[](){}` without
#     skipping quoted spans, so a bracket/paren inside a quoted value corrupted
#     their depth. They now skip quoted strings via `skip_string`.

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# Runs *block* with the global default (user-agent) stylesheet emptied, then
# restores it, so asserting `fg == nil` isn't foiled by the auto-installed theme.
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

private def parse(css : String)
  Crysterm::CSS::Stylesheet.parse(css)
end

describe "BUGS6 structural pseudo-classes vs sub-element pseudo-nodes (fix #1)" do
  it "matches :last-child on real list items despite the trailing <w-item> slot" do
    screen = headless_screen
    list = Widget::List.new
    screen.append list
    list.set_items(["a", "b", "c"])

    without_default_theme do
      # `List` always emits a trailing `<w-item>` sub-element node, which used to
      # steal the last-child slot from the real items.
      screen.stylesheet = <<-CSS
        List Box:first-child { color: green; }
        List Box:last-child { color: red; }
      CSS
      screen.apply_stylesheet

      list.items[0].styles.normal.fg.should eq rgb("green") # first-child (forward, always worked)
      list.items[1].styles.normal.fg.should be_nil
      list.items[2].styles.normal.fg.should eq rgb("red") # last-child now hits the real last item
    end
  end

  it "matches :nth-last-child counting only real children" do
    screen = headless_screen
    list = Widget::List.new
    screen.append list
    list.set_items(["a", "b", "c"])

    without_default_theme do
      screen.stylesheet = <<-CSS
        List Box:nth-last-child(1) { color: red; }
        List Box:nth-last-child(2) { color: green; }
      CSS
      screen.apply_stylesheet

      list.items[2].styles.normal.fg.should eq rgb("red")   # last
      list.items[1].styles.normal.fg.should eq rgb("green") # second from last
      list.items[0].styles.normal.fg.should be_nil
    end
  end

  it "matches :only-child on the sole real child of a scrollable box" do
    screen = headless_screen
    box = Widget::Box.new
    box.scrollbar = true # emits trailing <w-scrollbar>/<w-track> nodes
    only = Widget::Button.new
    box.append only
    screen.append box

    without_default_theme do
      screen.stylesheet = "Box > Button:only-child { color: red; }"
      screen.apply_stylesheet

      only.styles.normal.fg.should eq rgb("red")
    end
  end

  it "keeps :last-child working while slot rules still target the pseudo-nodes" do
    screen = headless_screen
    box = Widget::Box.new
    box.scrollbar = true
    b1 = Widget::Button.new
    b2 = Widget::Button.new
    b3 = Widget::Button.new
    box.append b1
    box.append b2
    box.append b3
    screen.append box

    without_default_theme do
      screen.stylesheet = <<-CSS
        Box > Button:first-child { color: green; }
        Box > Button:last-child { color: red; }
        Scrollbar { color: cyan; }
      CSS
      screen.apply_stylesheet

      b1.styles.normal.fg.should eq rgb("green")           # forward pseudo unaffected
      b2.styles.normal.fg.should be_nil                    # middle child untouched
      b3.styles.normal.fg.should eq rgb("red")             # backward pseudo now correct
      box.styles.normal.scrollbar.fg.should eq rgb("cyan") # slot node still matched
    end
  end

  it "does not regress forward :nth-child positions" do
    screen = headless_screen
    box = Widget::Box.new
    box.scrollbar = true
    a = Widget::Button.new
    b = Widget::Button.new
    c = Widget::Button.new
    box.append a
    box.append b
    box.append c
    screen.append box

    without_default_theme do
      screen.stylesheet = "Box > Button:nth-child(2) { color: red; }"
      screen.apply_stylesheet

      a.styles.normal.fg.should be_nil
      b.styles.normal.fg.should eq rgb("red")
      c.styles.normal.fg.should be_nil
    end
  end
end

describe "BUGS6 @media feature parsing (fix #2)" do
  it "does not match everywhere for a unit'd (px) feature" do
    q = Crysterm::CSS::MediaQuery.parse("(min-width: 80px)")
    q.conditions.should eq [{"min-width", 80}]
    q.matches?(100, 24, 256).should be_true
    q.matches?(50, 24, 256).should be_false # was: matched every width
  end

  it "folds feature names case-insensitively" do
    q = Crysterm::CSS::MediaQuery.parse("(Min-Width: 80)")
    q.conditions.should eq [{"min-width", 80}]
    q.matches?(100, 24, 256).should be_true
    q.matches?(50, 24, 256).should be_false
  end

  it "treats a media type (print) as unmatchable, not vacuously true" do
    q = Crysterm::CSS::MediaQuery.parse("print")
    q.matchable?.should be_false
    q.matches?(100, 24, 256).should be_false
  end

  it "treats an unknown feature as unmatchable" do
    q = Crysterm::CSS::MediaQuery.parse("(prefers-color-scheme: dark)")
    q.matchable?.should be_false
    q.matches?(100, 24, 256).should be_false
  end

  it "does not over-match when a recognized feature is ANDed with an unknown one" do
    q = Crysterm::CSS::MediaQuery.parse("(min-width: 80) and (orientation: portrait)")
    # width 100 satisfies min-width:80, but the unknown feature makes the whole
    # query unmatchable rather than applying on width alone.
    q.matches?(100, 24, 256).should be_false
  end

  it "applies a unit'd @media block only at the matching width (end-to-end)" do
    narrow = headless_screen
    narrow.width = 40
    b1 = Widget::Box.new
    narrow.append b1

    wide = headless_screen
    wide.width = 100
    b2 = Widget::Box.new
    wide.append b2

    without_default_theme do
      css = <<-CSS
        Box { color: white; }
        @media (min-width: 80px) { Box { color: green; } }
      CSS
      narrow.stylesheet = css
      narrow.apply_stylesheet
      wide.stylesheet = css
      wide.apply_stylesheet

      b1.styles.normal.fg.should eq rgb("white") # 40 < 80, media rule skipped (was: matched)
      b2.styles.normal.fg.should eq rgb("green") # 100 >= 80, media rule applies
    end
  end

  it "skips an @media print block on a terminal (end-to-end)" do
    screen = headless_screen
    screen.width = 100
    box = Widget::Box.new
    screen.append box

    without_default_theme do
      screen.stylesheet = <<-CSS
        Box { color: white; }
        @media print { Box { color: red; } }
      CSS
      screen.apply_stylesheet
      box.styles.normal.fg.should eq rgb("white") # print never matches a terminal
    end
  end
end

describe "BUGS6 quote-skipping selector scanners (fix #3)" do
  it "matches a paren inside a quoted var() fallback (matching_paren)" do
    # The `)` inside the quoted fallback must not close the var() call early.
    Crysterm::CSS::Stylesheet.resolve_var("var(--a, \"b)c\")", {} of String => String)
      .should eq "\"b)c\""
  end

  it "peels a state pseudo-class past a quoted ] in an attribute value" do
    # The `]` inside the quoted value must not prematurely close bracket depth,
    # or `:focus` would not be recognized as the subject's top-level state.
    rule = parse(%(Button[data-x="a]b"]:focus { color: red; })).rules.first
    rule.state.should eq Crysterm::WidgetState::Focused
  end

  it "keeps a quoted ) inside :has(...) from truncating the relational selector" do
    rule = parse("Button:has([title=\")\"]) { color: red; }").rules.first
    rule.has.should eq "[title=\")\"]" # full inner selector preserved
  end

  it "splits the subject past a quoted ] so ancestor :has() is peeled correctly" do
    # Without quote-skipping in split_subject, the quoted `]` corrupts depth, the
    # descendant combinator is missed, and `:has(.err)` is mistaken for a
    # subject-level `:has` instead of an ancestor-position one.
    rule = parse(%(Form[data-x="a]b"]:has(.err) Button { color: red; })).rules.first
    rule.ancestor_has.should_not be_nil
    rule.has.should be_nil
  end
end
