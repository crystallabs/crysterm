require "./spec_helper"

include Crysterm

# `CheckBox#check`/`#uncheck`/`#partial` override `AbstractButton`'s versions
# but used to drop the trailing `request_render`, so a programmatic state
# change (or a label-click routing through `press` → `toggle`) flipped
# `checked?` and the marker without scheduling a repaint. The marker-click and
# activate-key paths masked it by repainting themselves (in `CheckMarker`), but
# the public API and `RadioButton` (which inherits the repainting versions)
# disagreed.
#
# `request_render` both `damage_mark_dirty`s the widget (recording its
# top-level ancestor in the screen's pending dirty-roots set under
# `DamageTracking`) and calls `Window#render`. In a headless spec the render
# fiber never runs, so `Window#render` only rings the doorbell — the
# observable, synchronous effect of the fix is the scheduled repaint (dirty
# mark), not an updated cell.
#
# These specs render once, drain the damage set to a clean baseline, then mutate
# state with NO manual render and assert the widget got marked for repaint.
# `invalidate_css` (also called by `#check`) routes to the CSS dirty sets, not
# `@damage_dirty_roots`, so only `request_render` lands the checkbox in the
# damage set — drop it and the state still flips but every case below fails.
private def cbr_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false,
    optimization: Crysterm::OptimizationFlag::DamageTracking)
end

# True iff *w* is registered for a repaint in *s*'s pending damage set. These
# checkboxes are direct screen children (screen is not a `Widget`, so `parent`
# is nil), so each is its own root.
private def repaint_scheduled?(s : Crysterm::Window, w : Crysterm::Widget)
  s.@damage_dirty_roots.includes? w
end

describe "CheckBox programmatic state changes schedule a repaint" do
  it "schedules a repaint when checked programmatically" do
    s = cbr_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "Accept"
    s.repaint                   # paint once,
    s.@damage_dirty_roots.clear # then start from a clean damage set
    repaint_scheduled?(s, cb).should be_false

    cb.check # no manual render: the widget must schedule its own
    cb.checked?.should be_true
    repaint_scheduled?(s, cb).should be_true # `check`'s `request_render` marked it
  end

  it "schedules a repaint when unchecked programmatically" do
    s = cbr_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, checked: true, content: "Accept"
    s.repaint
    s.@damage_dirty_roots.clear
    repaint_scheduled?(s, cb).should be_false

    cb.uncheck
    cb.checked?.should be_false
    repaint_scheduled?(s, cb).should be_true
  end

  it "schedules a repaint when set to the partially-checked state" do
    s = cbr_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, tristate: true, content: "Accept"
    s.repaint
    s.@damage_dirty_roots.clear
    repaint_scheduled?(s, cb).should be_false

    cb.partial
    cb.partial?.should be_true
    repaint_scheduled?(s, cb).should be_true
  end

  it "schedules a repaint when toggled programmatically" do
    s = cbr_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, top: 0, left: 0, width: 20, height: 1, content: "Accept"
    s.repaint
    s.@damage_dirty_roots.clear
    repaint_scheduled?(s, cb).should be_false

    cb.toggle # routes through #check
    cb.checked?.should be_true
    repaint_scheduled?(s, cb).should be_true

    s.@damage_dirty_roots.clear
    cb.toggle # routes through #uncheck
    cb.checked?.should be_false
    repaint_scheduled?(s, cb).should be_true
  end
end
