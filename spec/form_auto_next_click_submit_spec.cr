require "./spec_helper"

include Crysterm

private def fan_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `auto_next` must advance focus when a field is submitted even if the user
# reached that field by a direct click (never Tabbing). The Submit handler was
# wired only lazily on the first `#focusable` (a Tab), so a click-then-submit
# never advanced; and even wired, it advanced from the stale `@selected` instead
# of the field that actually submitted.
describe Crysterm::Widget::Form do
  it "advances from the submitting field on a click-then-submit" do
    s = fan_window
    form = Crysterm::Widget::Form.new parent: s, keys: true, auto_next: true, width: 40, height: 20
    _le1 = Crysterm::Widget::LineEdit.new parent: form, name: "a", top: 0, height: 1, width: 20
    le2 = Crysterm::Widget::LineEdit.new parent: form, name: "b", top: 2, height: 1, width: 20
    le3 = Crysterm::Widget::LineEdit.new parent: form, name: "c", top: 4, height: 1, width: 20
    s._render

    # No Tab: focus le2 directly (as a click would), then submit it. Focus must
    # advance to le3 — not stay put and not jump to the first field.
    le2.focus
    le2.emit Crysterm::Event::Submitted, le2.value

    form.current_field.should eq le3
  end
end
