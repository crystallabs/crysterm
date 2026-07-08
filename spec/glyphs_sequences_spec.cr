require "./spec_helper"

include Crysterm

# GLYPHS.md phase 4: sequence (multi-char) roles — the `Glyphs.chars` registry
# layer, the CSS `glyphs:` property, its widget consumption (Loading spinner
# frames, Dial pointer ring, the chart fill ramps), and the opt-in
# `Glyphs.detected_tier` Extended heuristic.

private def gs_screen(width = 40, height = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

describe "Glyphs sequence registry" do
  it "answers the historical defaults per tier" do
    Glyphs.chars(Glyphs::SeqRole::SpinnerFrames, Glyphs::Tier::Unicode).should eq ['|', '/', '-', '\\']
    Glyphs.chars(Glyphs::SeqRole::SpinnerFrames, Glyphs::Tier::Extended).first.should eq '⠋'
    Glyphs.chars(Glyphs::SeqRole::DialPointers, Glyphs::Tier::Unicode).should eq ['↑', '↗', '→', '↘', '↓', '↙', '←', '↖']
    Glyphs.chars(Glyphs::SeqRole::ScaleHorizontal, Glyphs::Tier::Unicode).should eq " ▏▎▍▌▋▊▉█".chars
    Glyphs.chars(Glyphs::SeqRole::ScaleVertical, Glyphs::Tier::Unicode).should eq " ▁▂▃▄▅▆▇█".chars
  end

  it "keeps every role's ascii column 7-bit and every tier non-empty" do
    Glyphs::SeqRole.each do |role|
      Glyphs.chars(role, Glyphs::Tier::Ascii).each(&.ord.should(be < 128))
      Glyphs::Tier.each do |tier|
        Glyphs.chars(role, tier).empty?.should be_false
      end
    end
  end

  it "set_chars overrides with tier fall-down; reset restores" do
    Glyphs.set_chars Glyphs::SeqRole::SpinnerFrames, unicode: ['a', 'b']
    Glyphs.chars(Glyphs::SeqRole::SpinnerFrames, Glyphs::Tier::Unicode).should eq ['a', 'b']
    Glyphs.chars(Glyphs::SeqRole::SpinnerFrames, Glyphs::Tier::Ascii).should eq ['|', '/', '-', '\\']
    Glyphs.reset
    Glyphs.chars(Glyphs::SeqRole::SpinnerFrames, Glyphs::Tier::Unicode).should eq ['|', '/', '-', '\\']
  end
end

describe "CSS glyphs: property" do
  it "stores the sequence string; none clears; blank drops" do
    st = Style.new
    Crysterm::CSS::Properties.apply st, "glyphs", %("◐◓◑◒")
    st.glyphs.should eq "◐◓◑◒"
    st.specified?(:glyphs).should be_true
    Crysterm::CSS::Properties.apply st, "glyphs", ""
    st.glyphs.should eq "◐◓◑◒" # unchanged
    Crysterm::CSS::Properties.apply st, "glyphs", "none"
    st.glyphs.should be_nil
  end
end

describe "Loading spinner frames" do
  it "cycles the CSS-supplied frames" do
    s = gs_screen
    l = Widget::Loading.new parent: s, top: 0, left: 0, width: 20, height: 5
    s.stylesheet = %(Loading { glyphs: "◐◓◑◒"; })
    s.apply_stylesheet
    s._render
    l.icons.should eq ["◐", "◓", "◑", "◒"]
    l.step
    l.icon.content.should eq "◓"
  end

  it "keeps the classic default and pins explicit icons/spinner" do
    s = gs_screen
    l = Widget::Loading.new parent: s, top: 0, left: 0, width: 20, height: 5
    l.icons.should eq ["|", "/", "-", "\\"]

    pinned = Widget::Loading.new parent: s, top: 5, left: 0, width: 20, height: 5, spinner: :circle
    s.stylesheet = %(Loading { glyphs: "xy"; })
    s.apply_stylesheet
    s._render
    pinned.icons.should eq ["◐", "◓", "◑", "◒"] # spinner: pins over CSS
    l.icons.should eq ["x", "y"]                # unpinned follows CSS
  end
end

describe "Dial pointer ring" do
  it "sweeps a CSS-supplied ring and falls back to the registry arrows" do
    s = gs_screen
    d = Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 3, value: 0, show_value: false
    s._render
    # Value at minimum: pointer is "north" (↑) centered in the middle row.
    row = (0...9).map { |x| s.lines[d.atop + 1][d.aleft + x].char }.join
    row.includes?('↑').should be_true

    # Let `_render` drive the cascade: it must see `css_dirty?` to force a
    # full damage re-composite, or the direct-painting (content-less) dial
    # is skipped and keeps its stale pointer cells.
    s.stylesheet = %(Dial { glyphs: "NESW"; })
    s._render
    row = (0...9).map { |x| s.lines[d.atop + 1][d.aleft + x].char }.join
    row.includes?('N').should be_true
  end
end

describe "Chart fill ramps" do
  it "fills a Gauge with a CSS-supplied ramp" do
    s = gs_screen
    g = Widget::Gauge.new parent: s, top: 0, left: 0, width: 10, height: 1, value: 50.0
    s.stylesheet = %(Gauge { glyphs: " -=#"; })
    s.apply_stylesheet
    s._render
    row = (0...10).map { |x| s.lines[g.atop][g.aleft + x].char }.join
    row.includes?('#').should be_true  # filled cells use the ramp's full step
    row.includes?('█').should be_false # not the registry blocks
  end

  it "rejects a ramp with wide characters (cell fills) and uses the registry" do
    s = gs_screen
    g = Widget::Gauge.new parent: s, top: 0, left: 0, width: 10, height: 1, value: 50.0
    s.stylesheet = %(Gauge { glyphs: " 🚀"; })
    s.apply_stylesheet
    s._render
    row = (0...10).map { |x| s.lines[g.atop][g.aleft + x].char }.join
    row.includes?('█').should be_true
  end

  it "maps ramp_glyph proportionally for non-9-step ramps" do
    ramp = [' ', '#'] # 2 steps: empty / full
    Widget::Graph::Scale.ramp_glyph(ramp, 0, 0).should eq ' '
    Widget::Graph::Scale.ramp_glyph(ramp, 8, 0).should eq '#'
    Widget::Graph::Scale.ramp_glyph(ramp, 3, 0).should eq ' ' # < half
    Widget::Graph::Scale.ramp_glyph(ramp, 5, 0).should eq '#' # > half
    # 9-step ramp indexes 1:1 with the eighths.
    h = " ▏▎▍▌▋▊▉█".chars
    Widget::Graph::Scale.ramp_glyph(h, 3, 0).should eq '▍'
    Widget::Graph::Scale.ramp_glyph(h, 11, 1).should eq '▍'
  end
end

describe "Glyphs.detected_tier" do
  it "suggests Extended only for known modern-font terminals" do
    Glyphs.detected_tier({} of String => String).should eq Glyphs::Tier::Unicode
    Glyphs.detected_tier({"TERM" => "xterm-256color"}).should eq Glyphs::Tier::Unicode
    Glyphs.detected_tier({"KITTY_WINDOW_ID" => "1"}).should eq Glyphs::Tier::Extended
    Glyphs.detected_tier({"TERM_PROGRAM" => "WezTerm"}).should eq Glyphs::Tier::Extended
    Glyphs.detected_tier({"TERM_PROGRAM" => "ghostty"}).should eq Glyphs::Tier::Extended
    Glyphs.detected_tier({"TERM_PROGRAM" => "iTerm.app"}).should eq Glyphs::Tier::Extended
    Glyphs.detected_tier({"TERM" => "xterm-kitty"}).should eq Glyphs::Tier::Extended
  end
end
