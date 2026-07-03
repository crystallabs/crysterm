require "./spec_helper"

include Crysterm

# Regression for a stale, pre-probe color count frozen into `DrawCaps`.
#
# `Screen` builds its `Tput` with `probe: false` and snapshots `DrawCaps`
# (including `ncolors`) in the constructor, *before* the deferred live probe
# runs. The render hot path (`window_drawing.cr`) reads `caps.ncolors`, not the
# live `Screen#colors`. When the probe later confirms 24-bit truecolor via a
# DECRQSS SGR readback (raising `tput.features.number_of_colors` to 16M), the
# snapshot was never refreshed — so `tid`/diagnostics reported 16M while actual
# rendering kept downsampling every RGB color to the stale pre-probe palette
# (256 or fewer). Only reproduced on terminals whose truecolor support is found
# by the *probe* rather than by `COLORTERM`/terminfo (e.g. xterm on Linux).
#
# Fix: `Screen#probe!` recomputes `@draw_caps` after `@tput.probe!` runs.
#
# `Tput#probe!` no-ops on the non-tty IO used in specs, and the CI terminal may
# itself already detect truecolor at construction — so instead of driving a real
# DECRQSS round-trip, these tests reproduce the *staleness mechanism* directly:
# `Screen#colors` (and thus `compute_draw_caps`) funnels through the effective
# color depth, so widening `colors.depth` after construction stands in for the
# post-construction capability upgrade a live probe performs. The point under
# test is that `Screen#probe!` re-snapshots `DrawCaps` from the now-current
# depth, which is what the truecolor probe relies on.
private def probe_screen(width = 8, height = 2)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

describe "Screen#probe! draw_caps refresh" do
  saved_force = Crysterm::ColorForce::None
  prev_depth = Crysterm::ColorDepth::Auto

  before_each do
    saved_force = Crysterm::Config.screen_color_force
    prev_depth = Crysterm::Config.colors_depth
    Crysterm::Config.screen_color_force = Crysterm::ColorForce::None
    # Pin a low baseline depth so construction snapshots 256, independent of
    # the CI terminal's own detected capabilities.
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::Xterm256
  end

  after_each do
    Crysterm::Config.screen_color_force = saved_force
    Crysterm::Config.colors_depth = prev_depth
  end

  it "re-snapshots ncolors after the effective depth widens (as a probe would)" do
    s = probe_screen
    screen = s.screen

    # Baseline: the constructor's snapshot agrees with the live count.
    screen.colors.should eq 256
    screen.draw_caps.ncolors.should eq 256

    # Widen the effective depth after construction — what a live truecolor probe
    # does when it confirms 24-bit support and raises number_of_colors to 16M.
    Crysterm::Config.colors_depth = Crysterm::ColorDepth::TrueColor
    screen.colors.should eq 0x1000000      # live per-frame value tracks it...
    screen.draw_caps.ncolors.should eq 256 # ...but the snapshot is stale

    screen.probe! # must refresh the snapshot
    screen.draw_caps.ncolors.should eq 0x1000000
  end

  it "emits truecolor SGR when rendering after the probe refresh" do
    s = probe_screen
    screen = s.screen
    s.alloc

    Crysterm::Config.colors_depth = Crysterm::ColorDepth::TrueColor
    screen.probe!

    obuf = screen.output.as(IO::Memory)
    rgb = Attr.pack(0i64, Attr.pack_color(0xff8800), Attr::COLOR_DEFAULT)
    c = s.lines[0][0]; c.attr = rgb; c.char = 'A'
    s.lines[0].dirty = true
    obuf.clear
    s.draw

    emitted = String.new(obuf.to_slice)
    # Full 24-bit sequence for 0xff8800, not a `38;5;n` palette approximation.
    emitted.includes?("38;2;255;136;0").should be_true
    emitted.includes?("38;5;").should be_false
  end
end
