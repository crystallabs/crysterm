require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 wave-3 CSS findings: B16-27, B16-28, B16-29.

# B16-27 — `split_top_level` tracked paren depth but not quoted strings, so a
# quoted space glyph value shredded into bare `"` tokens and the whole
# declaration was dropped by the shorthand's token-count check.
describe "BUGS16 B16-27: quote-aware shorthand tokenization" do
  it "keeps a quoted space corner char in the border-chars group form" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-chars", %q{" " "x" "y"})
    s.border.@corner_char.should eq ' '
    s.border.@horizontal_char.should eq 'x'
    s.border.@vertical_char.should eq 'y'
  end

  it "still applies the unquoted forms" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-chars", %q{"a" "b" "c"})
    s.border.@corner_char.should eq 'a'
    s.border.@horizontal_char.should eq 'b'
    s.border.@vertical_char.should eq 'c'
  end
end

# B16-28 — `transition` split on EVERY comma, so a comma-bearing timing
# function (`cubic-bezier(...)`, `steps(...)`) was shredded into bogus
# pseudo-property entries and the real entries mis-parsed.
describe "BUGS16 B16-28: transition parsing with comma-bearing easing functions" do
  it "keeps cubic-bezier() inside one entry" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "transition", "color 0.3s cubic-bezier(0.4, 0, 0.2, 1)")
    tr = s.transitions.not_nil!
    tr.keys.should eq ["color"]
    tr["color"][0].should eq 0.3.seconds
  end

  it "parses a multi-entry list containing steps()" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "transition", "opacity steps(4, end), color 0.2s")
    tr = s.transitions.not_nil!
    tr.keys.sort!.should eq ["color", "opacity"]
    tr["color"][0].should eq 0.2.seconds
  end
end

# B16-29 — `currentColor` in border colors was resolved eagerly at
# declaration time, so `border-color: currentColor` declared BEFORE `color:`
# (or with the color arriving from another rule / the inheritance pass) left
# the border in the terminal-default color. A marker on `Border` now
# re-resolves marked slots against the element's effective fg at render time
# (`Border#side_fg`).
describe "BUGS16 B16-29: currentColor border resolves at render time" do
  it "picks up a color declared after border-color: currentColor" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-style", "solid")
    Crysterm::CSS::Properties.apply(s, "border-color", "currentColor")
    Crysterm::CSS::Properties.apply(s, "color", "red")
    s.border.fg_current_color?.should be_true
    red = Colors.convert_cached("red")
    s.fg.should eq red
    s.border.side_fg(Crysterm::Side::Top, s.fg).should eq red
    s.border.side_fg(Crysterm::Side::Left, s.fg).should eq red
  end

  it "keeps the eager resolution for the fg-set-first ordering" do
    s = Style.new(fg: 0xff0000)
    Crysterm::CSS::Properties.apply(s, "border-color", "currentColor")
    s.border.fg.should eq 0xff0000
    s.border.side_fg(Crysterm::Side::Top, s.fg).should eq 0xff0000
  end

  it "clears the marker when a concrete color is declared later" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "currentColor")
    Crysterm::CSS::Properties.apply(s, "border-color", "blue")
    s.border.fg_current_color?.should be_false
    Crysterm::CSS::Properties.apply(s, "color", "red")
    s.border.side_fg(Crysterm::Side::Top, s.fg).should eq Colors.convert_cached("blue")
  end

  it "tracks a per-side currentColor longhand independently" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-color", "currentColor")
    Crysterm::CSS::Properties.apply(s, "border-left-color", "cyan")
    Crysterm::CSS::Properties.apply(s, "color", "green")
    green = Colors.convert_cached("green")
    s.border.top_fg_current_color?.should be_true
    s.border.side_fg(Crysterm::Side::Top, s.fg).should eq green
    s.border.side_fg(Crysterm::Side::Left, s.fg).should eq Colors.convert_cached("cyan")
  end

  it "renders the border in the final text color regardless of declaration order" do
    s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
      error: IO::Memory.new, width: 24, height: 10, default_quit_keys: false)
    marked = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4
    Crysterm::CSS::Properties.apply(marked.style, "border-style", "solid")
    Crysterm::CSS::Properties.apply(marked.style, "border-color", "currentColor")
    Crysterm::CSS::Properties.apply(marked.style, "color", "red")

    control = Widget::Box.new parent: s, top: 5, left: 0, width: 10, height: 4
    Crysterm::CSS::Properties.apply(control.style, "border-style", "solid")
    Crysterm::CSS::Properties.apply(control.style, "color", "red")
    Crysterm::CSS::Properties.apply(control.style, "border-color", "currentColor")

    s._render
    s.lines[0][0].attr.should eq s.lines[5][0].attr
  ensure
    s.try &.destroy
  end
end
