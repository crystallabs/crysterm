require "./spec_helper"

include Crysterm

# OPT5/API4 ranged-value cluster: four related items bundled into one spec.
#
# * O5-10 — `RangedValue(T)#minimum=`/`#maximum=` and `PercentRange`'s were
#   identical carry-up/down twins in two mixins (one generic, one not), now
#   both sourced from a single duck-typed `Mixin::RangeBounds`
#   (src/mixin/ranged_value.cr), written purely against the includer's own
#   `#minimum`/`#maximum`/`#set_range` (no cross-generic trickery needed).
#   Pins that `Widget::Slider` (`RangedValue(Int32)`, via `AbstractSlider`)
#   and `Widget::Gauge` (`PercentRange`, `Float64`) carry identically.
# * O5-26 — `ProgressBar#range=`/`#span` were prose-enforced copies of
#   `RangedValue`'s. Now `Mixin::RangeSpan(T)` holds both, included by
#   `RangedValue(T)` *and* directly by `ProgressBar` (which can't include the
#   rest of `RangedValue` — its `complete:`-gated `Event::Completed` doesn't
#   fit `#value=`). Pins `#range=`'s exclusive-range collapse and that a
#   range-triggered re-clamp still routes through ProgressBar's own
#   `#set_range` (no spurious `Event::Completed`, matching the pre-refactor
#   behavior) plus `#span`'s overflow-safe widening (via `#percent`).
# * O5-27 — the pinnable CSS-overridable glyph accessors hand-rolled across
#   `ScrollBar`/`Slider` are now `Macros.pinnable_glyph(name, role, sub)`
#   (defined in src/widget/slider.cr, reachable from both via `Widget`'s
#   `include Macros`). Pins that the macro-generated accessors are still
#   pinnable via constructor keyword and still CSS-overridable when unpinned.
# * A4-61b — `RangedValue#on_value_change(&block)` now routes per
#   instantiation: `Event::ValueChanged` (`Int32`) by default,
#   `Event::DoubleValueChanged` (`Float64`) when `T == Float64`, mirroring
#   `#emit_value_change`'s own routing. Pins both instantiations via
#   `Widget::Slider` and `Widget::DoubleSpinBox`.
# * A4-62 — new `Event::SliderMoved` (payload: candidate position `Int32`,
#   defined in src/widget/slider.cr), emitted on every drag motion in
#   `Widget::Slider`/`Widget::ScrollBar`, independent of `#tracking?`. Pins
#   that with tracking off, `SliderMoved` fires on press+move while
#   `ValueChanged` fires only on release; with tracking on, `ValueChanged`
#   fires per move without being double-fired by the `SliderMoved` wiring.

private def o5rng_window(width = 80, height = 24) : Crysterm::Window
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height, default_quit_keys: false)
end

private def o5rng_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

# Drag helpers matching `AbstractSlider#drag_gesture?`'s actual condition: a
# `Move` needs a non-`None` button to count as part of a drag (unlike some
# other widgets' looser mouse handlers), so these — unlike some other specs'
# `move` helper — keep `Left` on the move too.
private def o5rng_press(s, x, y)
  s.dispatch_mouse o5rng_mouse(::Tput::Mouse::Action::Down, x, y)
end

private def o5rng_drag(s, x, y)
  s.dispatch_mouse o5rng_mouse(::Tput::Mouse::Action::Move, x, y)
end

private def o5rng_release(s, x, y)
  s.dispatch_mouse o5rng_mouse(::Tput::Mouse::Action::Up, x, y, ::Tput::Mouse::Button::None)
end

describe "O5-10: RangeBounds shared by RangedValue(T) and PercentRange" do
  it "carries identically on Slider (RangedValue(Int32)) and Gauge (PercentRange, Float64)" do
    s = o5rng_window
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 20, height: 1,
      minimum: 0, maximum: 10, value: 5

    # Qt's setMaximum: a new maximum below the current minimum carries the
    # minimum DOWN with it (collapses to the single value) rather than
    # inverting.
    sl.maximum = 3
    sl.minimum.should eq 3
    sl.maximum.should eq 3

    # Qt's setMinimum: a new minimum above the current maximum carries the
    # maximum UP with it.
    sl.minimum = 20
    sl.minimum.should eq 20
    sl.maximum.should eq 20

    g = Widget::Gauge.new parent: s, top: 1, left: 0, width: 20, height: 1,
      minimum: 0.0, maximum: 10.0, value: 5.0

    g.maximum = 3.0
    g.minimum.should eq 3.0
    g.maximum.should eq 3.0

    g.minimum = 20.0
    g.minimum.should eq 20.0
    g.maximum.should eq 20.0
  end
end

describe "O5-26: ProgressBar#range=/#span via Mixin::RangeSpan(Int32)" do
  it "collapses an exclusive range the same way RangedValue's does" do
    s = o5rng_window
    bar = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 20, height: 1,
      minimum: 0, maximum: 100, value: 0

    bar.range = 5...5 # degenerate empty exclusive range -> collapses to 5
    bar.minimum.should eq 5
    bar.maximum.should eq 5

    bar.range = 10...20 # exclusive -> inclusive 10..19
    bar.minimum.should eq 10
    bar.maximum.should eq 19
  end

  it "dispatches #range=/#set_range through ProgressBar's own #set_range, preserving the Completed-suppression on a range-triggered re-clamp" do
    s = o5rng_window
    bar = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 20, height: 1,
      minimum: 0, maximum: 100, value: 0

    completed = 0
    bar.on(Crysterm::Event::Completed) { completed += 1 }

    bar.value = 100
    completed.should eq 1 # value rose to maximum: Completed fires

    # Shrinking the range onto the current value is a reconfiguration, not a
    # completion — RangeSpan#range= must still land on ProgressBar's own
    # #set_range (complete: false), not RangedValue's generic one.
    bar.range = 0..50
    bar.maximum.should eq 50
    bar.value.should eq 50
    completed.should eq 1 # unchanged
  end

  it "#span stays overflow-safe at a full Int32 range (percent doesn't raise)" do
    s = o5rng_window
    bar = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 20, height: 1,
      minimum: 0, maximum: Int32::MAX, value: Int32::MAX
    bar.percent.should eq 100
  end
end

describe "O5-27: Macros.pinnable_glyph shared by Slider and ScrollBar" do
  it "Slider's macro-converted handle/track stay pinnable via constructor keyword" do
    s = o5rng_window
    Widget::Slider.new parent: s, top: 0, left: 0, width: 11, height: 1,
      minimum: 0, maximum: 10, value: 0, handle_char: '#', track_char: '-'
    s.repaint
    (0...11).map { |x| s.lines[0][x].char }.join.should eq "#----------"
  end

  it "Slider's handle is CSS-overridable when unpinned" do
    s = o5rng_window
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 11, height: 1,
      minimum: 0, maximum: 10, value: 0
    s.stylesheet = %(Slider::handle { glyph: "◆"; })
    s.apply_stylesheet
    s.repaint
    s.lines[0][sl.aleft].char.should eq '◆'
  end

  it "ScrollBar's macro-converted thumb/arrows stay pinnable" do
    s = o5rng_window
    sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 5,
      minimum: 0, maximum: 10, value: 0, stepper_buttons: true, thumb_char: '#'
    # `up_arrow_char=`/`down_arrow_char=` aren't constructor keywords (only
    # `thumb_char`/`trough_char` are) — assign post-construction, same as the
    # pre-macro hand-rolled setters accepted.
    sb.up_arrow_char = '^'
    sb.down_arrow_char = 'v'
    s.repaint
    s.lines[0][sb.aleft].char.should eq '^'
    s.lines[4][sb.aleft].char.should eq 'v'
  end

  it "ScrollBar's up-arrow is CSS-overridable when unpinned" do
    s = o5rng_window
    sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 5,
      minimum: 0, maximum: 10, value: 0, stepper_buttons: true
    s.stylesheet = %(ScrollBar::up-arrow { glyph: "^"; })
    s.apply_stylesheet
    s.repaint
    s.lines[0][sb.aleft].char.should eq '^'
  end
end

describe "A4-61b: RangedValue#on_value_change per-instantiation routing" do
  it "hands Slider's block an Int32 via Event::ValueChanged" do
    s = o5rng_window
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 20, height: 1,
      minimum: 0, maximum: 100, value: 0
    got = [] of Int32
    sl.on_value_change { |v| got << v }
    sl.value = 42
    sl.value = 42 # no-op, must not re-fire
    got.should eq [42]
  end

  it "hands DoubleSpinBox's block a Float64 via Event::DoubleValueChanged" do
    s = o5rng_window
    dsb = Widget::DoubleSpinBox.new parent: s, top: 0, left: 0, width: 20, height: 1,
      minimum: 0.0, maximum: 100.0, value: 0.0
    got = [] of Float64
    dsb.on_value_change { |v| got << v }
    dsb.value = 12.5
    got.should eq [12.5]
  end
end

describe "A4-62: Event::SliderMoved" do
  it "fires on every drag motion with tracking off, while ValueChanged fires only on release" do
    s = o5rng_window
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 21, height: 1,
      minimum: 0, maximum: 20, value: 0
    sl.tracking = false
    s.repaint

    value_changes = 0
    moved = [] of Int32
    sl.on(Crysterm::Event::ValueChanged) { value_changes += 1 }
    sl.on(Crysterm::Event::SliderMoved) { |e| moved << e.position }

    o5rng_press s, sl.aleft + 5, sl.atop
    moved.size.should eq 1
    value_changes.should eq 0

    o5rng_drag s, sl.aleft + 15, sl.atop
    moved.size.should eq 2
    value_changes.should eq 0
    (moved[1] > moved[0]).should be_true

    o5rng_release s, sl.aleft + 15, sl.atop
    value_changes.should eq 1   # committed exactly once, on release
    moved.size.should eq 2      # release itself emits no SliderMoved
    sl.value.should eq moved[1] # committed value matches the last drag candidate
  end

  it "fires alongside a per-move ValueChanged with tracking on, without double-firing ValueChanged" do
    s = o5rng_window
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 21, height: 1,
      minimum: 0, maximum: 20, value: 0
    # `#tracking?` defaults to `true`.
    s.repaint

    value_changes = 0
    moved = 0
    sl.on(Crysterm::Event::ValueChanged) { value_changes += 1 }
    sl.on(Crysterm::Event::SliderMoved) { moved += 1 }

    o5rng_press s, sl.aleft + 5, sl.atop
    value_changes.should eq 1
    moved.should eq 1

    o5rng_drag s, sl.aleft + 15, sl.atop
    value_changes.should eq 2
    moved.should eq 2

    o5rng_release s, sl.aleft + 15, sl.atop
    value_changes.should eq 2 # release commits nothing new (tracking already live)
    moved.should eq 2         # release emits no SliderMoved either
  end

  it "ScrollBar emits SliderMoved on drag too (shared gesture)" do
    s = o5rng_window
    sb = Widget::ScrollBar.new parent: s, top: 0, left: 0, width: 1, height: 21,
      minimum: 0, maximum: 20, value: 0
    sb.tracking = false
    s.repaint

    moved = [] of Int32
    sb.on(Crysterm::Event::SliderMoved) { |e| moved << e.position }

    o5rng_press s, sb.aleft, sb.atop + 10
    moved.size.should eq 1
    sb.value.should eq 0 # tracking off: press alone doesn't commit

    o5rng_release s, sb.aleft, sb.atop + 10
    sb.value.should eq moved[0]
  end
end
