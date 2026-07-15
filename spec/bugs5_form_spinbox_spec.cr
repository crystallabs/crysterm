require "./spec_helper"

include Crysterm

# Regression specs for BUGS5.
#
#  BUG 1 (already fixed in src/widget/form.cr): `Form#offset_focusable` used a
#     hardcoded `-1` start sentinel for both directions, so a backward step from
#     an unselected form landed on the second-to-last field. It is now
#     direction-aware. Covered by spec/bugs4_form_spec.cr; a guarding case for a
#     2-field form is added here (the smallest form that exposed the off-by-one).
#
#  BUG 2 (fixed in src/mixin/spinbox_editing.cr): `#commit_edit` routed the
#     parsed edit buffer straight through `#value=`. On a `#wrap?` box, `#value=`
#     treats any out-of-range value as a single-step overshoot and snaps to the
#     *opposite* bound, so typing an absolute value like 150 on a 0..100 wrap box
#     committed 0 (and -30 committed 100). A typed entry is an absolute value,
#     not a step, so `#commit_edit` now clamps it into range.

private def bugs5_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def keypress(ch : Char, key : Tput::Key? = nil)
  Crysterm::Event::KeyPress.new ch, key
end

private def type_and_commit(w, text : String)
  text.each_char { |c| w.on_keypress keypress(c) }
  w.on_keypress(Crysterm::Event::KeyPress.new('\r', Tput::Key::Enter))
end

describe "BUGS5 Form focus (bug 1, already fixed) — 2-field edge case" do
  it "#previous_focusable with no selection returns the LAST of two fields" do
    s = bugs5_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    Crysterm::Widget::Box.new(parent: form, keys: true, top: 0, left: 0, width: 5, height: 1)
    b = Crysterm::Widget::Box.new(parent: form, keys: true, top: 1, left: 0, width: 5, height: 1)
    s.render

    form.focusable.size.should eq 2

    # The 2-field case is where the old off-by-one flipped the result: backward
    # from an unselected form must land on field 1 (b), not field 0 (a).
    form.selected = nil
    form.previous_focusable.should eq b
  end

  it "#focus_last on a 3-field form focuses the last field (was second-to-last)" do
    s = bugs5_screen
    form = Crysterm::Widget::Form.new(parent: s, keys: true)
    fields = (0...3).map do |i|
      Crysterm::Widget::Box.new(parent: form, keys: true, top: i, left: 0, width: 5, height: 1)
    end
    s.render

    form.focus_last
    form.selected.should eq fields.last
  end
end

describe "BUGS5 SpinBox typed entry on a wrap box (bug 2)" do
  it "clamps a typed over-maximum entry instead of wrapping to the minimum" do
    s = bugs5_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10, wrapping: true
    type_and_commit sb, "150"
    sb.value.should eq 100 # clamped to maximum, NOT wrapped to 0
  end

  it "clamps a typed under-minimum entry instead of wrapping to the maximum" do
    s = bugs5_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: -50, maximum: 100, value: 10, wrapping: true
    type_and_commit sb, "-80"
    sb.value.should eq -50 # clamped to minimum, NOT wrapped to 100
  end

  it "still commits an in-range typed entry unchanged on a wrap box" do
    s = bugs5_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10, wrapping: true
    type_and_commit sb, "42"
    sb.value.should eq 42
  end

  it "still wraps on single-step overshoot (stepping past a bound)" do
    s = bugs5_screen
    sb = Crysterm::Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, step: 1, value: 100, wrapping: true
    sb.increment
    sb.value.should eq 0 # stepping (not typing) past the top still wraps
  end
end

describe "BUGS5 DoubleSpinBox typed entry on a wrap box (bug 2)" do
  it "clamps a typed over-maximum entry instead of wrapping to the minimum" do
    s = bugs5_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 10.0, wrapping: true
    type_and_commit d, "150"
    d.value.should eq 100.0 # clamped to maximum, NOT wrapped to 0.0
  end

  it "clamps a typed under-minimum entry instead of wrapping to the maximum" do
    s = bugs5_screen
    d = Crysterm::Widget::DoubleSpinBox.new parent: s, minimum: -50.0, maximum: 100.0, value: 10.0, wrapping: true
    type_and_commit d, "-80"
    d.value.should eq -50.0 # clamped to minimum, NOT wrapped to 100.0
  end
end
