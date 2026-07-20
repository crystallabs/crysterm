require "./spec_helper"

include Crysterm

# Regression specs for BUGS17 (terminal-emulator widget area).
#
#   B17-32  Widget::Terminal#apply_cursor — the :block cursor must TOGGLE
#           REVERSE (not OR it), so it stays visible on a cell the child already
#           rendered reversed (SGR 7). Mirrors the B16-05 fix in window_cursor.cr.
#   B17-34  Widget::Terminal#on_mouse — rows must map through the RENDERED
#           position (lpos.yi + lpos.base), not layout `atop`, so reports
#           forwarded to the child are correct inside a scrolled container.
#   B17-35  TerminalEmulator#resize — a column shrink that clips a wide-glyph
#           pair must not strand a bare wide lead in the last column.

private DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def b17_emu(cols = 6, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, DFL)
end

private def b17_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

private def b17_mouse(action, button, x, y)
  Crysterm::Event::Mouse.new(::Tput::Mouse::Event.new(action, button, x, y, source: :test))
end

# ── B17-32: block cursor stays visible on an already-reversed cell. ──
describe "Widget::Terminal block cursor toggles REVERSE (B17-32)" do
  it "clears REVERSE on a cell the child rendered reversed, so the cursor shows" do
    s = b17_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      cursor_shape: :block,
      handler: ->(_data : String) { nil })
    s._render
    term.focus

    em = term.emulator.not_nil!
    # Print 'X' with SGR 7 (reverse video), reset, then CHA back onto the X so
    # the block cursor lands on an already-reversed cell.
    em.feed "\e[7mX\e[0m\e[G"
    em.cursor_x.should eq 0
    s._render

    line = s.lines[0]
    line[0].char.should eq 'X'
    # B17-32: OR-ing REVERSE here was a no-op (cell already reversed) and the
    # cursor was invisible; toggling flips it back to normal video.
    (Attr.flags(line[0].attr) & Attr::REVERSE).should eq 0
  ensure
    term.try &.kill
    s.try &.destroy
  end

  it "still sets REVERSE on a normal (non-reversed) cell (no regression)" do
    s = b17_screen
    term = Crysterm::Widget::Terminal.new(
      parent: s, top: 0, left: 0, width: 10, height: 4,
      cursor_shape: :block,
      handler: ->(_data : String) { nil })
    s._render
    term.focus

    em = term.emulator.not_nil!
    em.feed "X\e[G" # plain 'X', cursor back onto it
    s._render

    line = s.lines[0]
    (Attr.flags(line[0].attr) & Attr::REVERSE).should_not eq 0
  ensure
    term.try &.kill
    s.try &.destroy
  end
end

# ── B17-35: resize column-shrink blanks a clipped wide lead. ──
describe "TerminalEmulator#resize wide-glyph column truncation (B17-35)" do
  it "blanks a wide lead stranded in the last column instead of leaving a width-2 char" do
    em = b17_emu(6, 4)
    # Place a wide (2-column) glyph in the last two columns (0-based 4 and 5).
    em.feed "\e[5G世"
    lead = em.lines[em.ydisp][4]
    lead.char.should eq '世'
    ::Crysterm::Unicode.width(lead.char).should eq 2

    # Shrink by one column: the CONTINUATION at index 5 is popped, which without
    # the repair would leave the bare width-2 lead as the last cell.
    em.resize(5, 4)

    last = em.lines[em.ydisp][4]
    last.char.should eq ' '
    ::Crysterm::Unicode.width(last.char).should eq 1
  end
end

# ── B17-34: on_mouse maps rows through the rendered position. ──
#
# A Terminal partially clipped by a scrolled ancestor: `#draw` paints the grid
# at `lpos.yi` with the clipped-top rows folded into `lpos.base`, so the mouse
# hit-map must undo exactly that. With the old layout-`atop` mapping the report
# forwarded to the child was off by the scroll offset (here the top rows were
# even dropped by the `row < 0` guard).
describe "Widget::Terminal#on_mouse row mapping in a scrolled container (B17-34)" do
  it "reports the emulator row under the pointer, not one offset by the scroll base" do
    captured = [] of String
    s = b17_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 8, scrollable: true
    term = Crysterm::Widget::Terminal.new(
      parent: outer, top: 0, left: 0, width: 10, height: 6,
      handler: ->(data : String) { captured << data; nil })
    # Tall spacer below so the container has room to scroll the terminal's top
    # rows off the viewport (child_base only moves past the interior height).
    Widget::Box.new parent: outer, top: 6, left: 0, width: 1, height: 30

    s._render
    outer.scroll_to 3, true
    s._render

    lp = term.lpos.not_nil!
    base = lp.base
    base.should be > 0 # the terminal's top `base` rows are clipped

    # Enable SGR encoding + normal (1000) mouse tracking on the child.
    term.write "\e[?1006h\e[?1000h"
    term.emulator.not_nil!.mouse_enabled?.should be_true

    # Point at a known VISIBLE content cell: `r_visible` rows below the painted
    # top (the clip edge), which maps to emulator row `base + r_visible`.
    r_visible = 1
    px = lp.xi + term.ileft + 2
    py = lp.yi + term.itop + r_visible

    captured.clear
    term.on_mouse b17_mouse(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, px, py)

    captured.size.should eq 1
    # SGR report: ESC [ < Cb ; Xcol ; Yrow (M|m). Rows/cols are 1-based.
    m = captured.last.match!(/\e\[<\d+;(\d+);(\d+)[Mm]/)
    reported_row0 = m[2].to_i - 1
    # The corrected mapping: emulator row under the pointer.
    reported_row0.should eq base + r_visible
  ensure
    term.try &.kill
    s.try &.destroy
  end
end
