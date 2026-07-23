require "./spec_helper"

include Crysterm

# Regression specs for the BUGS18 effects cluster:
#
#   * B18-84 — `Spray#recompute` computed `cycle = fill_frame + hold` and, in
#     repeat mode, `@frame % cycle`. With `spacing: 0, travel: 0, hold: 0`
#     ("fill instantly, loop immediately") the cycle was 0 and the modulo
#     raised `DivisionByZeroError`, killing the animation fiber and leaving
#     `running?` stuck. The cycle is now floored at 1, so the degenerate
#     configuration renders the fully-landed pattern instead (and a negative
#     `hold` can no longer freeze the spray in the pending-spark state).
#
#   * B18-85 — `Effect::Direct#paint` (and `SineScroller#render`) derived the
#     simulation size from the clip-adjusted visible rectangle. Each scroll
#     step of a clipping ancestor changed the visible height, re-running
#     `resize` and wiping the whole simulation state, while the visible slice
#     showed a re-simulated shrunken field instead of the correct region of
#     the full one. Both now size from the UNCLIPPED interior and map visible
#     cells through the clip (rows via `coords.base`, columns via the
#     unclipped origin), per the `Widget::Terminal#draw` convention.
#
#   * B18-86 — `Spray#pattern=`/`#fill=` were plain setters whose values are
#     consumed only when slots are (re)built, which happened only in `resize`
#     — a mid-run reassignment silently did nothing until an unrelated
#     resize. `origin=` was half-live: the emitter moved but a `Fill::Radial`
#     order stayed sorted around the old origin. All three now apply live.
#
#   * B18-88 — `Effect::Animated#interval=` only wrote the widget ivar; the
#     running `FrameClock` keeps its own copy (read live each tick), so a
#     cadence change was inert until stop/start. The setter now forwards to
#     the running clock.
#
# Everything is driven headlessly over in-memory IOs; `#render`/`#advance` are
# synchronous, and the one `#start` below never yields to its fiber.

private def fx_win(w = 30, h = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def cell_char(s, y, x)
  s.lines[y][x].char
end

# Minimal `Effect::Direct` includer instrumenting the module's contract calls
# (`resize`/`cell`), so the shared paint path can be asserted without a full
# simulation. `cell` encodes the FULL-FIELD row into the glyph (`'A' + y`), so
# the screen shows which field row each visible cell was mapped to.
private class ProbeEffect < Crysterm::Widget::Box
  include Crysterm::Widget::Effect::Direct

  getter resize_calls = [] of Tuple(Int32, Int32)
  getter cell_sizes = [] of Tuple(Int32, Int32)
  getter cell_rows = [] of Int32

  def resize(w : Int32, h : Int32)
    @resize_calls << {w, h}
  end

  def advance(w : Int32, h : Int32)
  end

  def cell(x : Int32, y : Int32, w : Int32, h : Int32) : {Char, Int32}
    @cell_sizes << {w, h}
    @cell_rows << y
    {'A' + y, -1}
  end

  # Expose the private frame clock for the B18-88 forwarding assertion.
  def clock
    @animation
  end
end

# Exposes the otherwise-encapsulated slot set, so the live-setter specs can
# assert the visit order / glyphs directly.
private class ProbeSpray < Crysterm::Widget::Effect::Spray
  def slots
    @slots
  end
end

describe "BUGS18 B18-84: Spray degenerate cycle" do
  it "runs a spacing=0/travel=0/hold=0 spray without raising and renders the landed pattern" do
    s = fx_win 12, 6
    sp = Widget::Effect::Spray.new parent: s, top: 0, left: 0, width: 6, height: 4,
      spacing: 0, travel: 0, hold: 0
    sp.resize 6, 4
    # Pre-fix: cycle == 0 and `@frame % 0` raised DivisionByZeroError on the
    # first advance, killing the animation fiber unrecoverably.
    3.times { sp.advance 6, 4 }
    # With the cycle floored at 1 every slot is landed each frame: the full
    # pattern shows instead of a dead fiber.
    sp.cell(0, 0, 6, 4)[0].should eq '▒'
    sp.cell(5, 3, 6, 4)[0].should eq '▒'
  ensure
    s.try &.destroy
  end

  it "does not raise on a negative hold driving the cycle below zero" do
    s = fx_win 12, 6
    sp = Widget::Effect::Spray.new parent: s, top: 0, left: 0, width: 4, height: 3,
      spacing: 1, travel: 1, hold: -100
    sp.resize 4, 3
    # Pre-fix `f = @frame % cycle` took the negative divisor's sign, wedging
    # the spray in the pending-spark state (with a 1-frame landed flicker).
    3.times { sp.advance 4, 3 }
  ensure
    s.try &.destroy
  end
end

describe "BUGS18 B18-85: clipped Effect::Direct keeps the full-size simulation" do
  it "sizes the simulation from the unclipped interior and maps visible cells through the clip" do
    s = fx_win 20, 12
    par = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4,
      scrollable: true
    eff = ProbeEffect.new parent: par, top: 0, left: 0, width: 10, height: 8
    par.child_base = 2
    s.repaint

    # Pre-fix: resize {10, 4} — the visible slice. The simulation must be
    # allocated at the full 10x8 interior.
    eff.resize_calls.should eq [{10, 8}]
    eff.cell_sizes.uniq.should eq [{10, 8}]
    # The 2 rows hidden above the clip edge (`coords.base`) offset the lookup:
    # the visible rows are FIELD rows 2..5, not 0..3.
    eff.cell_rows.min.should eq 2
    eff.cell_rows.max.should eq 5
    # Screen row 0 shows field row 2.
    cell_char(s, 0, 0).should eq 'C'
    cell_char(s, 3, 9).should eq 'F'
  ensure
    s.try &.destroy
  end

  it "does not resize (wipe) the simulation as the ancestor scrolls" do
    s = fx_win 20, 12
    par = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4,
      scrollable: true
    eff = ProbeEffect.new parent: par, top: 0, left: 0, width: 10, height: 8
    s.repaint
    eff.resize_calls.should eq [{10, 8}]

    # A frame ticks (marking the effect dirty, so damage tracking re-renders
    # it) at each scroll position — the real scroll-during-animation case. The
    # raw `child_base=` setter alone doesn't dirty the clipped child.
    par.child_base = 1
    eff.step
    s.repaint
    par.child_base = 2
    eff.step
    s.repaint

    # Pre-fix each scroll step changed the visible height and re-ran `resize`,
    # resetting the whole effect state (Fire heat, Matrix drops, Spray slots)
    # per step.
    eff.resize_calls.should eq [{10, 8}]
    cell_char(s, 0, 0).should eq 'C'
  ensure
    s.try &.destroy
  end

  it "keeps the SineScroller wave geometry of the full inner field while clipped" do
    s = fx_win 30, 12
    par = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 4,
      scrollable: true
    sc = Widget::Effect::SineScroller.new parent: par, top: 0, left: 0,
      width: 20, height: 8, text: "A" * 20, rainbow: false
    par.child_base = 2
    s.repaint

    sc.running?.should be_false # never started; frame stays 0
    hits = 0
    (0...20).each do |x|
      # Full-field wave row for column x at frame 0 — the amplitude comes from
      # the FULL height 8, not the visible 4 (pre-fix: amp squashed to 1.5 and
      # every row re-mapped into the slice).
      r = (3.5 * (1.0 + Math.sin(x * 0.32))).round.to_i.clamp(0, 7)
      col = (0...4).map { |sy| cell_char(s, sy, x) }
      if 2 <= r < 6
        col[r - 2].should eq 'A'
        hits += 1
      else
        # Wave row outside the visible slice: the column stays background.
        col.should eq [' ', ' ', ' ', ' ']
      end
    end
    hits.should be > 0
  ensure
    s.try &.destroy
  end
end

describe "BUGS18 B18-86: Spray pattern=/fill=/origin= apply live" do
  it "respells the existing slots on pattern= without waiting for a resize" do
    s = fx_win 12, 6
    sp = ProbeSpray.new parent: s, top: 0, left: 0, width: 6, height: 3, fill: :rows
    s.repaint # paints once, building the slots at the interior size
    sp.slots.first[2].should eq '▒'

    sp.pattern = "AB"
    # Pre-fix: nothing changed until an unrelated resize. The glyphs must be
    # remapped in place, keeping the visit order (rows: {0,0} then {1,0}).
    sp.slots.map { |sl| sl[2] }.first(4).should eq ['A', 'B', 'A', 'B']
    sp.slots.first.should eq({0, 0, 'A'})
    sp.slots[1].should eq({1, 0, 'B'})
  ensure
    s.try &.destroy
  end

  it "rebuilds the visit order on fill=" do
    s = fx_win 12, 6
    sp = ProbeSpray.new parent: s, top: 0, left: 0, width: 6, height: 3, fill: :rows
    s.repaint
    sp.slots[1][0..1].should eq({1, 0}) # row-major

    sp.fill = Widget::Effect::Spray::Fill::Columns
    # Pre-fix the old row-major slots kept projecting forever.
    sp.slots[1][0..1].should eq({0, 1}) # column-major
  ensure
    s.try &.destroy
  end

  it "re-sorts a Fill::Radial order around a new origin=" do
    s = fx_win 12, 6
    sp = ProbeSpray.new parent: s, top: 0, left: 0, width: 6, height: 3,
      fill: :radial, origin: {0, 0}
    s.repaint
    sp.slots.first[0..1].should eq({0, 0}) # nearest the old emitter

    sp.origin = {5, 2}
    # Pre-fix glyphs launched from the new origin but landed in the OLD
    # origin's radial order.
    sp.slots.first[0..1].should eq({5, 2})
  ensure
    s.try &.destroy
  end

  it "keeps an origin-independent order intact on origin= and is safe before the first paint" do
    s = fx_win 12, 6
    sp = ProbeSpray.new parent: s, top: 0, left: 0, width: 6, height: 3, fill: :random
    s.repaint
    before = sp.slots.dup
    sp.origin = {5, 2}
    # Only a Radial order depends on the emitter — a Random landed layout must
    # not be reshuffled by an emitter move.
    sp.slots.should eq before

    # Setters on a never-painted spray (no known size yet) must not raise.
    sp2 = ProbeSpray.new parent: s, top: 3, left: 0, width: 6, height: 3
    sp2.pattern = "XY"
    sp2.fill = Widget::Effect::Spray::Fill::Random
    sp2.origin = {1, 1}
    sp2.slots.empty?.should be_true
  ensure
    s.try &.destroy
  end
end

describe "BUGS18 B18-88: Animated#interval= forwards to the running clock" do
  it "updates the running FrameClock's cadence live" do
    s = fx_win 12, 6
    eff = ProbeEffect.new parent: s, top: 0, left: 0, width: 6, height: 3
    eff.start
    begin
      clock = eff.clock.not_nil!
      clock.interval.should eq 0.07.seconds

      eff.interval = 0.02.seconds
      eff.interval.should eq 0.02.seconds
      # Pre-fix the clock kept its construction-time copy until stop/start.
      clock.interval.should eq 0.02.seconds
    ensure
      eff.stop
    end
  ensure
    s.try &.destroy
  end

  it "still works as a plain assignment on a stopped effect" do
    s = fx_win 12, 6
    eff = ProbeEffect.new parent: s, top: 0, left: 0, width: 6, height: 3
    eff.interval = 0.01.seconds
    eff.interval.should eq 0.01.seconds
  ensure
    s.try &.destroy
  end
end
