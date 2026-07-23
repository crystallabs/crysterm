require "./spec_helper"

include Crysterm

# Regression specs for the BUGS18 transition/animation batch:
#
# * B18-92 — `transition: tint` tweened the raw `tint_alpha` field (0.5 even
#   with no tint color), so a tint declared only in the highlight state snapped
#   in/out with zero animation; the effective tint (color + strength via
#   `Style#tint?`) must be eased, carrying the color, and a tint-to-tint change
#   with equal strengths but different colors must cross-fade.
# * B18-94 — `transition_color` fed the `-1` terminal-default sentinel straight
#   into `Colors.mix`, which reads its bits as `0xFFFFFF`: the tween blended
#   through white and permanently stamped literal white into the per-state
#   style instead of restoring `-1`. Keyframe fg/bg lerps had the same defect,
#   and their settle frame must stamp the RAW endpoint (`-1`), not the
#   configured substitute.
# * B18-96 — `apply_keyframe` gave fg/bg only the both-endpoints lerp, without
#   the single-sided constant carry the opacity/tint channels have, so a color
#   declared at a stop whose segment partner omits it was never rendered.

private def sized_screen(w, h)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "B18-92 transition: tint eases the effective tint" do
  it "fades a tint in on enter and out on exit when declared only in the state rule" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "t92"
    s.stylesheet = ".t92 { transition: tint 0.2s linear; } " \
                   ".t92:hover { tint: #ff0000 0.8; }"
    s.repaint
    b.style.tint?.should be_nil # no tint in the normal state

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.1.seconds            # ~halfway through the 0.2s linear tween
    mid = b.style.tint?.not_nil! # overlay already visible: color carried, strength easing
    mid[0].should eq 0xff0000
    (0.05 <= mid[1] <= 0.75).should be_true # mid-fade, not snapped to 0.8

    sleep 0.25.seconds
    b.style.tint?.should eq({0xff0000, 0.8}) # landed on target

    b.state = Crysterm::WidgetState::Normal
    sleep 0.1.seconds
    out = b.style.tint?.not_nil! # fade-out keeps the color while strength eases down
    out[0].should eq 0xff0000
    (0.1 <= out[1] <= 0.7).should be_true

    sleep 0.25.seconds
    b.style.tint?.should be_nil # final tick lands on alpha 0.0: overlay inert again
  end

  it "cross-fades a tint-to-tint change with equal strengths but different colors" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "t92b"
    s.stylesheet = ".t92b { tint: #0000ff 0.5; transition: tint 0.2s linear; } " \
                   ".t92b:hover { tint: #ff0000 0.5; }"
    s.repaint
    b.style.tint?.should eq({0x0000ff, 0.5})

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.1.seconds
    mid = b.style.tint?.not_nil! # equal strengths must not no-op the tween
    mid[0].should_not eq 0x0000ff
    mid[0].should_not eq 0xff0000 # mid-blend between blue and red

    sleep 0.25.seconds
    b.style.tint?.should eq({0xff0000, 0.5}) # landed exactly on target
  end
end

describe "B18-94 transition_color and the -1 terminal-default sentinel" do
  it "tweens toward `transparent` via the substitute RGB and restores raw -1 on completion" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "v94"
    s.stylesheet = ".v94 { color: #ffffff; transition: color 0.2s linear; } " \
                   ".v94:hover { color: transparent; }"
    s.repaint
    b.style.fg.should eq 0xffffff

    b.state = Crysterm::WidgetState::Hovered
    sleep 0.1.seconds
    # Pre-fix every tick wrote mix(-1, #ffffff, v) = 0xFFFFFF (white-to-white);
    # fixed, the tween blends toward the configured default (0xc0c0c0), so the
    # mid value is never pure white.
    b.style.fg.should_not eq 0xffffff

    sleep 0.25.seconds
    # Natural completion must restore the exact raw target — the sentinel -1 —
    # not permanently stamp the final mix product (pre-fix: literal 0xFFFFFF).
    b.style.fg.should eq(-1)
  end

  it "keyframe settle stamps the raw -1 endpoint, not white or the substitute" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "g94"
    s.stylesheet = "@keyframes ghost { from { color: #ff0000; } to { color: transparent; } } " \
                   ".g94 { color: #123456; animation: ghost 0.15s linear 1; }"
    s.repaint
    sleep 0.35.seconds # past the single iteration: settle branch ran at frac 1.0
    # Pre-fix: lerp read -1's bits as 0xFFFFFF and stamped white permanently.
    b.style.fg.should eq(-1)
  end
end

describe "B18-96 apply_keyframe carries a one-sided fg/bg constant" do
  it "applies a color declared only at the 0% stop across the cycle" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "k96"
    s.stylesheet = "@keyframes alert { 0% { color: #ff0000; } 100% { opacity: 1.0; } } " \
                   ".k96 { animation: alert 0.2s linear infinite; }"
    s.repaint
    sleep 0.15.seconds
    # One-sided color must be carried as a constant — same rule the identically
    # shaped opacity declaration already follows.
    b.style.fg.should eq 0xff0000
    b.style.opacity.should eq 1.0
  end

  it "applies a background-color declared only at one stop" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "k96b"
    s.stylesheet = "@keyframes bgc { 0% { background-color: #00ff00; } 100% { opacity: 0.5; } } " \
                   ".k96b { animation: bgc 0.2s linear infinite; }"
    s.repaint
    sleep 0.15.seconds
    b.style.bg.should eq 0x00ff00
  end

  it "carries a color declared at 0%/100% but not 50% across both segments" do
    s = sized_screen 10, 3
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "k96c"
    s.stylesheet = "@keyframes tri { 0% { color: #0000ff; } 50% { opacity: 0.3; } 100% { color: #0000ff; } } " \
                   ".k96c { animation: tri 0.2s linear infinite; }"
    s.repaint
    sleep 0.05.seconds
    b.style.fg.should eq 0x0000ff # first segment: carry from the 0% stop
    sleep 0.11.seconds
    b.style.fg.should eq 0x0000ff # second segment: carry from the 100% stop
  end
end
