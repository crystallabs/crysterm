require "./spec_helper"

include Crysterm

private def te_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# An `input_on_focus` field grabs the keyboard and, when it loses focus, used to
# unconditionally `rewind_focus` — which yanked focus straight back to itself.
# That made `Tab`/click navigation between the fields of a form (e.g. the Pine
# `Compose` screen) impossible: focus never actually advanced. The fix only
# rewinds when focus is *cleared* (no successor), not when it deliberately moves
# to another widget.
describe "input_on_focus focus hand-off" do
  it "moves focus to another field instead of bouncing back" do
    s = te_screen
    a = Crysterm::Widget::LineEdit.new parent: s, top: 0, height: 1, input_on_focus: true
    b = Crysterm::Widget::LineEdit.new parent: s, top: 1, height: 1, input_on_focus: true

    a.focus
    s.focused.should eq a

    # Deliberately move focus to the second field (what Tab / a click does).
    b.focus
    s.focused.should eq b
  end

  it "can hand focus back and forth repeatedly" do
    s = te_screen
    a = Crysterm::Widget::LineEdit.new parent: s, top: 0, height: 1, input_on_focus: true
    b = Crysterm::Widget::LineEdit.new parent: s, top: 1, height: 1, input_on_focus: true

    a.focus
    b.focus
    a.focus
    s.focused.should eq a
    b.focus
    s.focused.should eq b
  end
end
