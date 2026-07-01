require "./spec_helper"

alias M = Crysterm::Widget::Media
alias G = Crysterm::Widget::Media::Glyph

# Capability gating for the high-resolution glyph families. The Unicode
# legacy-computing ranges (sextants U+1FB00, octants U+1CD00) have no runtime
# probe, so support is decided from terminal identity + version
# (`Tput::Emulator#legacy_computing_sextant?` / `#legacy_computing_octant?`):
# the ranges are gated *separately*, known font-dependent macOS terminals are
# excluded, and everything else is trusted (optimistic default).

# A Tput whose Unicode is forced on and whose terminal identity is set
# explicitly, independent of the host terminal (probe suppressed). Env-derived
# identity flags (the host may set ITERM_SESSION_ID etc.) are cleared so each
# test starts from a blank, unidentified terminal.
private def build_tput
  ti = (Unibilium.from_env rescue Unibilium.from_terminal("xterm"))
  tput = Tput.new(terminfo: ti, input: STDIN, output: STDOUT, probe: false, force_unicode: true)
  emu = tput.emulator
  emu.iterm2 = false
  emu.osxterm = false
  emu.kitty = false
  tput
end

describe "Crysterm::Widget::Media glyph capability" do
  it "excludes iTerm2/Apple Terminal from both ranges" do
    tput = build_tput
    tput.emulator.iterm2 = true
    tput.emulator.legacy_computing_sextant?.should be_false
    tput.emulator.legacy_computing_octant?.should be_false

    tput.emulator.iterm2 = false
    tput.emulator.osxterm = true
    tput.emulator.legacy_computing_sextant?.should be_false
    tput.emulator.legacy_computing_octant?.should be_false
  end

  it "trusts unidentified terminals for both ranges (optimistic default)" do
    tput = build_tput # no identity flags set → #identity is nil
    tput.emulator.legacy_computing_sextant?.should be_true
    tput.emulator.legacy_computing_octant?.should be_true
  end

  it "version-gates octants independently of sextants" do
    tput = build_tput
    tput.emulator.kitty = true

    # No detectable version → assume current (optimistic): both ranges on.
    tput.emulator.legacy_computing_sextant?.should be_true
    tput.emulator.legacy_computing_octant?.should be_true

    # Old kitty renders sextants but not the newer octants (OCTANT_SUPPORT
    # requires >= 0.40.0; kitty is absent from SEXTANT_SUPPORT so stays on).
    tput.features.terminal_version = "kitty(0.39.0)"
    tput.emulator.legacy_computing_sextant?.should be_true
    tput.emulator.legacy_computing_octant?.should be_false

    # From the gated version on, octants come back.
    tput.features.terminal_version = "kitty(0.40.0)"
    tput.emulator.legacy_computing_octant?.should be_true
  end

  it "gates Octant/Sextant availability while leaving universal families available" do
    tput = build_tput
    tput.emulator.iterm2 = true

    # High-res legacy-computing families are unavailable on iTerm2...
    M.available?(M::Type::GlyphOctant, tput).should be_false
    M.available?(M::Type::GlyphSextant, tput).should be_false
    # ...but the universal families still render.
    M.available?(M::Type::GlyphQuadrant, tput).should be_true
    M.available?(M::Type::GlyphHalf, tput).should be_true
    M.available?(M::Type::GlyphBraille, tput).should be_true
    # And the cell-grid variants (previously mis-reported as unavailable).
    M.available?(M::Type::AnsiC256, tput).should be_true

    # On a legacy-computing terminal, octant is available.
    tput.emulator.iterm2 = false
    tput.emulator.kitty = true
    M.available?(M::Type::GlyphOctant, tput).should be_true
  end

  it "best_mode walks the resolution ladder to the highest supported family" do
    tput = build_tput

    # Full legacy-computing support → the densest family.
    tput.emulator.kitty = true
    G.best_mode(tput).should eq G::Mode::Octant

    # Sextants but not octants → the next rung down.
    tput.features.terminal_version = "kitty(0.39.0)"
    G.best_mode(tput).should eq G::Mode::Sextant

    # No legacy-computing at all → universal block elements.
    tput.emulator.kitty = false
    tput.emulator.iterm2 = true
    G.best_mode(tput).should eq G::Mode::Quadrant
  end
end
