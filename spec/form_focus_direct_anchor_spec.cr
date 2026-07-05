require "./spec_helper"

include Crysterm

private def ffd_window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# When a form field is focused directly (e.g. a mouse click into it) rather than
# via Tab, the next Tab must continue from the field that actually holds focus —
# not from the stale last-navigated `#selected`.
describe Crysterm::Widget::Form do
  it "resumes Tab navigation from the directly-focused field" do
    s = ffd_window
    form = Crysterm::Widget::Form.new parent: s, keys: true, width: 40, height: 20
    f0 = Crysterm::Widget::LineEdit.new parent: form, name: "f0", top: 0, height: 1, width: 20
    _f1 = Crysterm::Widget::LineEdit.new parent: form, name: "f1", top: 2, height: 1, width: 20
    f2 = Crysterm::Widget::LineEdit.new parent: form, name: "f2", top: 4, height: 1, width: 20
    f3 = Crysterm::Widget::LineEdit.new parent: form, name: "f3", top: 6, height: 1, width: 20
    s._render

    form.focus_next
    form.selected.should eq f0

    # Focus f2 directly, bypassing the form's navigation.
    f2.focus
    s.focused.should eq f2

    # The next step must land on f3 (after the *focused* f2), not f1 (after the
    # stale @selected f0).
    form.focus_next
    form.selected.should eq f3
  end

  it "still enters from the first/last field via focus_first/focus_last" do
    s = ffd_window
    form = Crysterm::Widget::Form.new parent: s, keys: true, width: 40, height: 20
    a = Crysterm::Widget::LineEdit.new parent: form, name: "a", top: 0, height: 1, width: 20
    _b = Crysterm::Widget::LineEdit.new parent: form, name: "b", top: 2, height: 1, width: 20
    c = Crysterm::Widget::LineEdit.new parent: form, name: "c", top: 4, height: 1, width: 20
    s._render

    # Even with a field already focused, focus_first/last enter from the ends.
    c.focus
    form.focus_first
    form.selected.should eq a
    form.focus_last
    form.selected.should eq c
  end
end
