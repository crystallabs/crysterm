require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 core findings C3, C7, C9, C16
# (src/window_drawing.cr):
#
# C3  — the BCE clear-to-EOL gate compared only REVERSE parity, so a run of
#       UNDERLINE/STRIKE blanks was erased with `el` (background fill only) —
#       visibly undecorated, and permanently so (`@flushed_lines` mirrored as-drawn).
# C7  — `with_scroll_region` restored DECSTBM to the *inline band* on a
#       non-alt surface, breaking the next `scroll_terminal_up` (newlines are
#       emitted at the terminal's LAST row, below the band's bottom).
# C9  — `invalidate_region`'s '\0' poison equals `Cell::CONTINUATION`, so a
#       wide glyph straddling the rect's LEFT edge compared unchanged and was
#       never re-emitted.
# C16 — `fill_region` cleared glyphs via raw array writes but never the OSC-8
#       link overlay, leaving invisible clickable regions on blanked cells.

private def b13dr_window(w = 40, h = 5, **opts)
  Crysterm::Window.new(
    **opts,
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS13 C3: BCE gate covers UNDERLINE/STRIKE, not just REVERSE" do
  it "does not clear an underlined blank run with el" do
    w = b13dr_window
    w.optimization = Crysterm::OptimizationFlag::BCE
    out = w.output.as(IO::Memory)

    # Previous frame: visible content on row 1.
    w.fill_region w.default_attr, 'x', 0, w.awidth, 1, 2
    w.draw
    out.clear

    # This frame: the whole row becomes *underlined* spaces (e.g. an underlined
    # blank field). `el` fills with background only, so it must NOT be used.
    ul = Attr.pack(Attr::UNDERLINE, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)
    w.fill_region ul, ' ', 0, w.awidth, 1, 2
    w.draw

    s = out.to_s
    s.includes?("\e[K").should be_false # not erased...
    s.includes?("\e[4m").should be_true # ...but printed with underline SGR
  end

  it "still uses el for plain (default-flag) blank runs" do
    w = b13dr_window
    w.optimization = Crysterm::OptimizationFlag::BCE
    out = w.output.as(IO::Memory)

    w.fill_region w.default_attr, 'x', 0, w.awidth, 1, 2
    w.draw
    out.clear

    w.fill_region w.default_attr, ' ', 0, w.awidth, 1, 2
    w.draw
    out.to_s.includes?("\e[K").should be_true
  end
end

describe "BUGS13 C7: inline CSR ops hand the whole terminal back" do
  it "restores DECSTBM to the full screen, not the inline band" do
    w = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 5, alternate: false, default_quit_keys: false)
    w.render_row_offset = 3
    out = w.output.as(IO::Memory)
    out.clear

    # A CSR-backed line op sets the region for the op, then must restore.
    w.delete_line 1, 0, 0, 4
    w.draw

    regions = out.to_s.scan(/\e\[(\d+);(\d+)r/)
    regions.empty?.should be_false
    last = regions.last
    # Full screen (1-based DECSTBM): rows 1..terminal-height — NOT the band
    # `[offset+1, offset+aheight]` (which would be 4;8 here).
    last[1].should eq "1"
    last[2].should eq w.tput.screen.height.to_s

    w.destroy
  end

  it "keeps the full-surface restore on an alt-screen window" do
    w = b13dr_window(40, 5)
    out = w.output.as(IO::Memory)
    out.clear

    w.delete_line 1, 0, 0, 4
    w.draw

    regions = out.to_s.scan(/\e\[(\d+);(\d+)r/)
    regions.empty?.should be_false
    last = regions.last
    last[1].should eq "1"
    last[2].should eq w.aheight.to_s

    w.destroy
  end
end

describe "BUGS13 C9: invalidate_region repaints a wide glyph straddling its left edge" do
  it "re-emits the lead cell when the rect's left edge lands on a continuation cell" do
    w = b13dr_window(20, 3, force_unicode: true, full_unicode: true)
    w.full_unicode_effective?.should be_true
    out = w.output.as(IO::Memory)

    # A wide glyph occupying columns 4 (lead) and 5 (continuation) on row 1.
    line = w.lines[1]
    line[4].char = '日'
    line[5].continuation!
    line.dirty = true
    w.draw
    out.to_s.includes?("日").should be_true
    out.clear

    # Invalidate a rect whose LEFT edge is the continuation column. The '\0'
    # poison equals the continuation sentinel, so pre-fix nothing repainted.
    w.invalidate_region 5, 10, 1, 2
    w.draw
    out.to_s.includes?("日").should be_true

    w.destroy
  end
end

describe "BUGS13 C16: fill_region clears the link overlay" do
  it "drops links when blanking linked cells" do
    w = b13dr_window
    line = w.lines[1]
    line[3].char = 'a'
    line.set_link 3, 7_u16
    line.has_links?.should be_true

    w.fill_region w.default_attr, ' ', 0, 10, 1, 2

    line.link_at(3).should eq 0_u16
    line.has_links?.should be_false
    w.destroy
  end

  it "rewrites an already-blank cell that still carries a link" do
    w = b13dr_window
    line = w.lines[1]
    # Cell content already equals the fill (default attr + space): pre-fix the
    # write guard skipped it entirely, keeping the stale link.
    line.set_link 2, 9_u16

    w.fill_region w.default_attr, ' ', 0, 10, 1, 2

    line.link_at(2).should eq 0_u16
    line.has_links?.should be_false
    w.destroy
  end
end
