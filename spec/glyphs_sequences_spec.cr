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

# Every env var the `Tput::Emulator` identity and `Features#detect_unicode`
# read. Cleared (then selectively set) around each identity-controlled `Tput`
# below, so the result never depends on the terminal the suite runs in.
GT_ENV_KEYS = %w[
  KITTY_WINDOW_ID WEZTERM_PANE WEZTERM_EXECUTABLE TERM_PROGRAM
  TERM_PROGRAM_VERSION ITERM_SESSION_ID XTERM_VERSION KONSOLE_VERSION
  MLTERM VTE_VERSION COLORTERM TERMINATOR_UUID TMUX TERM
  NCURSES_FORCE_UNICODE XTERM_LOCALE LANG LANGUAGE LC_ALL LC_CTYPE
]

private def with_gt_env(vars : Hash(String, String), &)
  saved = {} of String => String?
  GT_ENV_KEYS.each { |k| saved[k] = ENV[k]?; ENV.delete k }
  vars.each { |k, v| ENV[k] = v }
  begin
    yield
  ensure
    GT_ENV_KEYS.each { |k| (v = saved[k]) ? (ENV[k] = v) : ENV.delete(k) }
  end
end

# A tput detached from any real terminal; identity comes only from the env
# `with_gt_env` staged. `force_unicode: false` means auto-detect, which with
# the locale vars cleared resolves to no Unicode.
private def gt_tput(force_unicode = true)
  ::Tput.new(terminfo: nil, input: IO::Memory.new, output: IO::Memory.new,
    force_unicode: force_unicode, probe: false)
end

describe "Glyphs.detected_tier(tput) and Screen auto glyph tier" do
  it "detects Extended from the emulator identity, gated on unicode" do
    with_gt_env({"KITTY_WINDOW_ID" => "1", "TERM" => "xterm"}) do
      gt_tput.emulator.modern_font?.should be_true
      Glyphs.detected_tier(gt_tput).should eq Glyphs::Tier::Extended
      # Same identity but no Unicode output: extended glyphs are unreasonable.
      Glyphs.detected_tier(gt_tput(force_unicode: false)).should eq Glyphs::Tier::Unicode
    end
    with_gt_env({"TERM_PROGRAM" => "WezTerm", "TERM" => "xterm"}) do
      Glyphs.detected_tier(gt_tput).should eq Glyphs::Tier::Extended
    end
    with_gt_env({"TERM" => "xterm"}) do
      gt_tput.emulator.modern_font?.should be_false
      Glyphs.detected_tier(gt_tput).should eq Glyphs::Tier::Unicode
    end
  end

  it "never auto-upgrades a headless (non-tty) screen" do
    with_gt_env({"KITTY_WINDOW_ID" => "1", "TERM" => "xterm"}) do
      s = Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new,
        width: 40, height: 12)
      s.glyph_tier.should eq Glyphs::Tier::Unicode
    end
  end

  it "keeps an explicitly assigned tier pinned across probe!" do
    s = Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new,
      width: 40, height: 12)
    s.glyph_tier = Glyphs::Tier::Ascii
    s.probe! # no-op round-trip on a non-tty; must not touch the pinned tier
    s.glyph_tier.should eq Glyphs::Tier::Ascii
  end
end
