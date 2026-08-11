require "./spec_helper"

include Crysterm

# Qt-model Tab traversal for forms: one focus ring per window, walked the same
# way in both directions (see QApplicationPrivate::focusNextPrevChild_helper).
# The Form handles no Tab/Shift+Tab of its own — the window's `tab_navigation`
# enters the form at its first entry, steps through, and continues past the
# last entry to the next widget outside, symmetrically. The form container
# itself is never a Tab stop (like a `NoFocus` Qt container), while vi j/k
# remain form-level and keep wrapping within it.

describe "Form Tab traversal is window-driven (Qt one-ring model)" do
  it "tabs into, through and out of the form — symmetric in both directions" do
    s = headless_screen(80, 24)
    before = Crysterm::Widget::Box.new parent: s, keys: true, top: 0, left: 0, width: 5, height: 1
    form = Crysterm::Widget::Form.new parent: s, keys: true, top: 2, left: 0, width: 40, height: 6
    f1 = Crysterm::Widget::Box.new parent: form, keys: true, top: 0, left: 0, width: 5, height: 1
    f2 = Crysterm::Widget::Box.new parent: form, keys: true, top: 1, left: 0, width: 5, height: 1
    after = Crysterm::Widget::Box.new parent: s, keys: true, top: 10, left: 0, width: 5, height: 1
    s.repaint

    before.focus
    tab = -> { s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::Tab) }
    backtab = -> { s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::ShiftTab) }

    # Forward: enters at the first entry (skipping the form container),
    # steps through, then leaves to the next widget outside.
    tab.call
    s.focused.same?(f1).should be_true
    tab.call
    s.focused.same?(f2).should be_true
    tab.call
    s.focused.same?(after).should be_true

    # Backward is the exact mirror: re-enters at the LAST entry.
    backtab.call
    s.focused.same?(f2).should be_true
    backtab.call
    s.focused.same?(f1).should be_true
    backtab.call
    s.focused.same?(before).should be_true
  end

  it "never lands Tab focus on the form container itself" do
    s = headless_screen(80, 24)
    form = Crysterm::Widget::Form.new parent: s, keys: true, top: 0, left: 0, width: 40, height: 6
    f1 = Crysterm::Widget::Box.new parent: form, keys: true, top: 0, left: 0, width: 5, height: 1
    s.repaint

    form.keyable?.should be_true # still receives bubbled keys...
    form.accepts_tab_focus?.should be_false

    # ...but a full cycle of Tab presses from its only entry always returns to
    # the entry, never stopping on the container.
    f1.focus
    s.emit Crysterm::Event::KeyPress, kp(key: Tput::Key::Tab)
    s.focused.same?(f1).should be_true
  end

  it "keeps vi j/k cycling within the form, wrapping at its edges" do
    s = headless_screen(80, 24)
    outside = Crysterm::Widget::Box.new parent: s, keys: true, top: 8, left: 0, width: 5, height: 1
    form = Crysterm::Widget::Form.new parent: s, keys: true, vi_keys: true, top: 0, left: 0, width: 40, height: 6
    f1 = Crysterm::Widget::Box.new parent: form, keys: true, top: 0, left: 0, width: 5, height: 1
    f2 = Crysterm::Widget::Box.new parent: form, keys: true, top: 1, left: 0, width: 5, height: 1
    s.repaint

    f1.focus
    s.emit Crysterm::Event::KeyPress, kp('j')
    s.focused.same?(f2).should be_true
    s.emit Crysterm::Event::KeyPress, kp('j') # wraps, stays inside the form
    s.focused.same?(f1).should be_true
    s.emit Crysterm::Event::KeyPress, kp('k') # wraps backward too
    s.focused.same?(f2).should be_true
    outside.focused?.should be_false
  end
end
