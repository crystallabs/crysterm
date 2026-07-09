require "./spec_helper"

include Crysterm

# BUGS12 #38 — a nested `@media` REPLACED the enclosing `@media` condition
# instead of AND-ing with it (CSS Conditional Rules): in
# `@media (min-width: 100) { Box { @media (max-height: 20) { … } } }` the inner
# rule applied on any short terminal even when the width guard failed. The fix
# combines outer and inner queries via `MediaQuery#and` — the cross-product of
# their OR-groups, each pairing AND-ing (concatenating) its conditions.

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def rgb(name)
  Crysterm::Colors.convert(name).to_i32
end

# The media condition of the single guarded rule in *css* (the parse must
# produce exactly one rule carrying a query).
private def guarded_media(css)
  media = Crysterm::CSS::Stylesheet.parse(css).rules.compact_map(&.media)
  media.size.should eq 1
  media.first
end

describe "BUGS12 #38 nested @media ANDs with the enclosing condition" do
  it "applies the inner rule only when BOTH conditions hold (all four truth combinations)" do
    q = guarded_media <<-CSS
      @media (min-width: 100) { Box { @media (max-height: 20) { color: red; } } }
      CSS
    q.matches?(120, 10, 256).should be_true  # width ok, height ok
    q.matches?(120, 30, 256).should be_false # width ok, height fails
    q.matches?(50, 10, 256).should be_false  # width fails, height ok (the bug: matched)
    q.matches?(50, 30, 256).should be_false  # both fail
  end

  it "ANDs direct @media-in-@media nesting (no intervening selector)" do
    q = guarded_media <<-CSS
      @media (min-width: 100) { @media (max-height: 20) { Box { color: red; } } }
      CSS
    q.matches?(120, 10, 256).should be_true
    q.matches?(120, 30, 256).should be_false
    q.matches?(50, 10, 256).should be_false
    q.matches?(50, 30, 256).should be_false
  end

  it "cross-products OR groups on both sides" do
    # (w<=40 OR w>=100) AND (h<=10 OR h>=50)
    q = guarded_media <<-CSS
      @media (max-width: 40), (min-width: 100) {
        Box { @media (max-height: 10), (min-height: 50) { color: red; } }
      }
      CSS
    q.groups.size.should eq 4               # 2 outer × 2 inner groups
    q.matches?(30, 5, 256).should be_true   # narrow AND short
    q.matches?(30, 60, 256).should be_true  # narrow AND tall
    q.matches?(120, 5, 256).should be_true  # wide AND short
    q.matches?(120, 60, 256).should be_true # wide AND tall
    q.matches?(70, 5, 256).should be_false  # width in the gap
    q.matches?(30, 25, 256).should be_false # height in the gap
    q.matches?(70, 25, 256).should be_false # both in the gap
  end

  it "survives an intervening @layer block (media threads through)" do
    q = guarded_media <<-CSS
      @media (min-width: 100) { @layer base { Box { @media (max-height: 20) { color: red; } } } }
      CSS
    q.matches?(120, 10, 256).should be_true
    q.matches?(50, 10, 256).should be_false
  end

  it "an unmatchable enclosing query poisons the nested rule" do
    q = guarded_media <<-CSS
      @media print { Box { @media (max-height: 20) { color: red; } } }
      CSS
    q.matchable?.should be_false
    q.matches?(120, 10, 256).should be_false
  end

  it "leaves a top-level single @media unchanged" do
    q = guarded_media "@media (min-width: 80) and (max-width: 120) { Box { color: red; } }"
    q.groups.size.should eq 1
    q.conditions.should eq [{"min-width", 80}, {"max-width", 120}]
    q.matches?(100, 24, 256).should be_true
    q.matches?(50, 24, 256).should be_false
  end

  it "applies the nested rule end-to-end only when both guards hold" do
    css = <<-CSS
      Box { color: white; }
      @media (min-width: 100) { Box { @media (max-height: 20) { color: green; } } }
      CSS
    {
      {120, 10, "green"}, # both hold
      {120, 30, "white"}, # height guard fails
      {50, 10, "white"},  # width guard fails (pre-fix: green)
      {50, 30, "white"},  # both fail
    }.each do |(w, h, expected)|
      screen = headless_screen
      screen.width = w
      screen.height = h
      box = Widget::Box.new
      screen.append box
      screen.stylesheet = css
      screen.apply_stylesheet
      box.styles.normal.fg.should eq rgb(expected)
    end
  end
end
