require "./spec_helper"

include Crysterm

# A4-64: `Event::EditingFinished` — Qt's `editingFinished` for persistent form
# fields. Contract (documented on the event in src/event.cr):
#
#   * `LineEdit` (the `Mixin::TextEditing` read session): exactly one emission
#     when the read session ends — Enter (submit), focus-out, or Escape (which
#     ends the whole session in this model). Never doubles with `Submitted`
#     when Enter both submits and ends the session.
#   * Spin boxes (`Mixin::SpinBoxEditing`): emitted when Enter commits a typed
#     entry and on every focus-out (unconditionally, as `QAbstractSpinBox`
#     does); silent in-place discards (Escape, step/wheel over a half-typed
#     entry) are not finishes.
#
# A4-65: `AbstractSpinBox#clear` — empties the *displayed* edit text only; the
# committed value is untouched until a new valid entry commits.

private def enter_key
  kp '\r', Tput::Key::Enter
end

describe "A4-64 Event::EditingFinished" do
  describe "LineEdit (read session)" do
    it "fires once on Enter, alongside a single Submitted (no double-fire)" do
      s = headless_screen(80, 24)
      le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
      s.repaint

      finished = 0
      submitted = 0
      le.on(Event::EditingFinished) { finished += 1 }
      le.on(Event::Submitted) { submitted += 1 }

      le.focus # input_on_focus (the default) has the read session running
      le.emit kp('h')
      le.emit enter_key

      finished.should eq 1
      submitted.should eq 1
      le.value.should eq "h"
    end

    it "fires once when the session ends by focus moving to another widget" do
      s = headless_screen(80, 24)
      le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
      other = Widget::Box.new parent: s, keys: true, top: 2, left: 0, width: 5, height: 1
      s.repaint

      finished = 0
      submitted = 0
      cancelled = 0
      le.on(Event::EditingFinished) { finished += 1 }
      le.on(Event::Submitted) { submitted += 1 }
      le.on(Event::Cancelled) { cancelled += 1 }

      le.focus
      le.emit kp('h')
      other.focus # FocusOut ends the read session

      finished.should eq 1
      submitted.should eq 0 # focus loss is not a submit...
      cancelled.should eq 1 # ...it cancels, but the edit session still finished
      le.value.should eq "h"
    end

    it "fires once when Escape ends the session (session-model divergence from Qt)" do
      s = headless_screen(80, 24)
      le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
      s.repaint

      finished = 0
      submitted = 0
      le.on(Event::EditingFinished) { finished += 1 }
      le.on(Event::Submitted) { submitted += 1 }

      le.focus
      le.emit kp('h')
      le.emit kp(key: Tput::Key::Escape)

      finished.should eq 1
      submitted.should eq 0
    end
  end

  describe "SpinBox (typing session)" do
    it "fires once when Enter commits a typed entry" do
      s = headless_screen(80, 24)
      sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
      s.repaint

      finished = 0
      sb.on(Event::EditingFinished) { finished += 1 }

      sb.handle_key_press kp('4')
      sb.handle_key_press kp('2')
      sb.handle_key_press enter_key

      finished.should eq 1
      sb.value.should eq 42
    end

    it "fires on focus-out — unconditionally, as QAbstractSpinBox does" do
      s = headless_screen(80, 24)
      sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
      other = Widget::Box.new parent: s, keys: true, top: 3, left: 0, width: 5, height: 1
      s.repaint

      finished = 0
      sb.on(Event::EditingFinished) { finished += 1 }

      sb.focus
      sb.handle_key_press kp('4') # half-typed entry...
      other.focus                 # ...abandoned by focus loss

      finished.should eq 1
      sb.value.should eq 10 # the half-typed 4 was discarded, not committed
      sb.editing?.should be_false
    end

    it "a silent in-place discard (Escape) is not a finish" do
      s = headless_screen(80, 24)
      sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
      s.repaint

      finished = 0
      sb.on(Event::EditingFinished) { finished += 1 }

      sb.handle_key_press kp('4')
      sb.handle_key_press kp(key: Tput::Key::Escape)

      finished.should eq 0
      sb.value.should eq 10
    end

    it "stepping over a half-typed entry (its discard) is not a finish" do
      s = headless_screen(80, 24)
      sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 10
      s.repaint

      finished = 0
      sb.on(Event::EditingFinished) { finished += 1 }

      sb.handle_key_press kp('4')
      sb.handle_key_press kp(key: Tput::Key::Up) # discards the buffer, then steps

      finished.should eq 0
      sb.value.should eq 11
    end

    it "DoubleSpinBox shares the Enter-commit emission" do
      s = headless_screen(80, 24)
      d = Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 100.0, value: 10.0
      s.repaint

      finished = 0
      d.on(Event::EditingFinished) { finished += 1 }

      d.handle_key_press kp('2')
      d.handle_key_press kp('.')
      d.handle_key_press kp('5')
      d.handle_key_press enter_key

      finished.should eq 1
      d.value.should eq 2.5
    end
  end
end

describe "A4-65 AbstractSpinBox#clear" do
  it "blanks the displayed text, leaving the committed value untouched" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 42,
      prefix: "$", suffix: "%"
    sb.text.should eq "$42%"

    sb.clear

    sb.text.should eq "$%"     # only prefix/suffix remain
    sb.value.should eq 42      # value unchanged until a new valid commit
    sb.editing?.should be_true # clear opens an (empty) typing session
  end

  it "typing after clear builds a fresh entry; Enter commits it" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 42
    sb.clear
    sb.handle_key_press kp('7')
    sb.handle_key_press kp('\r', Tput::Key::Enter)
    sb.value.should eq 7
    sb.text.should eq "7"
  end

  it "Enter on a still-empty cleared buffer restores the committed display" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 42
    sb.clear
    sb.handle_key_press kp('\r', Tput::Key::Enter)
    sb.editing?.should be_false
    sb.text.should eq "42"
    sb.value.should eq 42
  end

  it "Escape after clear restores the committed display" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 42
    sb.clear
    sb.handle_key_press kp(key: Tput::Key::Escape)
    sb.editing?.should be_false
    sb.text.should eq "42"
    sb.value.should eq 42
  end

  it "clear mid-edit blanks the in-progress buffer" do
    s = headless_screen(80, 24)
    sb = Widget::SpinBox.new parent: s, minimum: 0, maximum: 100, value: 42
    sb.handle_key_press kp('9')
    sb.text.should eq "9"
    sb.clear
    sb.text.should eq ""
    sb.value.should eq 42
  end

  it "DoubleSpinBox inherits clear with the same semantics" do
    s = headless_screen(80, 24)
    d = Widget::DoubleSpinBox.new parent: s, minimum: 0.0, maximum: 10.0, value: 1.5
    d.text.should eq "1.50"
    d.clear
    d.text.should eq ""
    d.value.should eq 1.5
  end
end
