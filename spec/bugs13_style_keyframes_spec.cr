require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 keyframes/animation batch:
#
# * S2 — `@keyframes` inside `@media` keeps the guard: a media-gated override
#   must not clobber the general definition on every terminal; the lookup
#   picks the last definition whose guard matches.
# * S8 — a stylesheet swap whose `animation:` declaration is unchanged but
#   whose `@keyframes` body changed (or vanished) restarts/stops the running
#   animation instead of ticking the stale stops forever.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Exposes the CSS-animation internals for assertions.
private class AnimProbe < Crysterm::Widget::Box
  def anim_clock
    @css_animation
  end

  def anim_stops
    @css_animation_keyframes
  end

  def stop_anim
    stop_css_animation
  end
end

describe "BUGS13 S2 @keyframes honors the enclosing @media guard" do
  css = <<-CSS
    @keyframes fade { from { opacity: 0; } to { opacity: 1; } }
    @media (min-width: 200) {
      @keyframes fade { from { opacity: 1; } to { opacity: 0.5; } }
    }
    CSS

  it "keeps both definitions and picks by terminal size" do
    sheet = Crysterm::CSS::Stylesheet.parse(css)
    narrow = sheet.keyframes_for("fade", 80, 24, 256).not_nil!
    narrow.first[1]["opacity"].should eq "0" # the general definition
    wide = sheet.keyframes_for("fade", 220, 24, 256).not_nil!
    wide.first[1]["opacity"].should eq "1" # the media-gated override
  end

  it "returns nil when only an unmatched guarded definition exists" do
    sheet = Crysterm::CSS::Stylesheet.parse(
      "@media (min-width: 200) { @keyframes f { from { opacity: 0; } to { opacity: 1; } } }")
    sheet.keyframes_for("f", 80, 24, 256).should be_nil
    sheet.keyframes_for("f", 220, 24, 256).should_not be_nil
  end

  it "keeps last-definition-wins among unguarded definitions" do
    sheet = Crysterm::CSS::Stylesheet.parse(<<-CSS)
      @keyframes a { from { color: red; } to { color: blue; } }
      @keyframes a { from { color: green; } to { color: blue; } }
      CSS
    sheet.keyframes_for("a", 80, 24, 256).not_nil!.first[1]["color"].should eq "green"
  end

  it "ANDs a nested @media guard around @keyframes" do
    sheet = Crysterm::CSS::Stylesheet.parse(<<-CSS)
      @media (min-width: 100) { @media (max-height: 20) {
        @keyframes g { from { opacity: 0; } to { opacity: 1; } }
      } }
      CSS
    sheet.keyframes_for("g", 120, 10, 256).should_not be_nil
    sheet.keyframes_for("g", 120, 30, 256).should be_nil
    sheet.keyframes_for("g", 50, 10, 256).should be_nil
  end

  it "Window#css_keyframes resolves against the terminal's size" do
    narrow = headless_screen(80, 24)
    narrow.stylesheet = css
    narrow.css_keyframes("fade").not_nil!.first[1]["opacity"].should eq "0"

    wide = headless_screen(220, 24)
    wide.stylesheet = css
    wide.css_keyframes("fade").not_nil!.first[1]["opacity"].should eq "1"
  end

  it "returns identity-stable stops across lookups (animation staleness check relies on it)" do
    screen = headless_screen(80, 24)
    screen.stylesheet = css
    screen.css_keyframes("fade").not_nil!.same?(screen.css_keyframes("fade").not_nil!).should be_true
  end
end

describe "BUGS13 S8 stylesheet swap refreshes a running CSS animation" do
  it "picks up a changed @keyframes body when the animation: declaration is unchanged" do
    screen = headless_screen
    box = AnimProbe.new parent: screen, width: 5, height: 3
    box.add_css_class "anim"
    begin
      screen.stylesheet = <<-CSS
        .anim { animation: pulse 60s infinite; }
        @keyframes pulse { from { opacity: 0.1; } to { opacity: 0.9; } }
        CSS
      screen.repaint
      clock1 = box.anim_clock
      clock1.should_not be_nil
      box.anim_stops.not_nil!.last[1]["opacity"].should eq "0.9"

      # Hot-reload: same `animation:` declaration, different keyframes body.
      screen.stylesheet = <<-CSS
        .anim { animation: pulse 60s infinite; }
        @keyframes pulse { from { opacity: 0.2; } to { opacity: 0.4; } }
        CSS
      screen.repaint
      clock2 = box.anim_clock
      clock2.should_not be_nil
      clock2.not_nil!.same?(clock1.not_nil!).should be_false # restarted
      box.anim_stops.not_nil!.last[1]["opacity"].should eq "0.4"
    ensure
      box.try &.stop_anim
    end
  end

  it "does not churn the clock when nothing changed" do
    screen = headless_screen
    box = AnimProbe.new parent: screen, width: 5, height: 3
    box.add_css_class "anim"
    begin
      screen.stylesheet = <<-CSS
        .anim { animation: pulse 60s infinite; }
        @keyframes pulse { from { opacity: 0.1; } to { opacity: 0.9; } }
        CSS
      screen.repaint
      clock1 = box.anim_clock
      clock1.should_not be_nil
      screen.repaint
      box.anim_clock.not_nil!.same?(clock1.not_nil!).should be_true
    ensure
      box.try &.stop_anim
    end
  end

  it "stops the clock when the @keyframes definition is removed" do
    screen = headless_screen
    box = AnimProbe.new parent: screen, width: 5, height: 3
    box.add_css_class "anim"
    begin
      screen.stylesheet = <<-CSS
        .anim { animation: pulse 60s infinite; }
        @keyframes pulse { from { opacity: 0.1; } to { opacity: 0.9; } }
        CSS
      screen.repaint
      box.anim_clock.should_not be_nil

      screen.stylesheet = ".anim { animation: pulse 60s infinite; }" # keyframes gone
      screen.repaint
      box.anim_clock.should be_nil
      # And the failed lookup is not re-attempted every render (memo settled).
      screen.repaint
      box.anim_clock.should be_nil
    ensure
      box.try &.stop_anim
    end
  end
end
