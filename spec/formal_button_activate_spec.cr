require "./spec_helper"

# FORMAL-WIDGETS Part B / B5.1 + B5.4 — the button family's keyboard-activation
# wiring lives once in `AbstractButton`. `handle Event::KeyPress` is registered by
# `AbstractButton#initialize` (not re-declared per subclass, so a subclass can no
# longer be silently dead to the keyboard), and the single `#on_keypress`
# dispatches to a `#activate` hook: push buttons (`Button`/`ToolButton`) `#press`,
# the marker controls (`CheckBox`/`RadioButton`, via `Mixin::CheckMarker`)
# `#toggle`. This pins that a Space/Enter keypress, delivered through the base
# handler, reaches the right activation for every member.

private def fba_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def space_key
  Crysterm::Event::KeyPress.new ' ', nil
end

private def enter_key
  Crysterm::Event::KeyPress.new '\r', ::Tput::Key::Enter
end

describe "FORMAL-WIDGETS B5.1/B5.4 — family-wide keyboard activation" do
  it "Button activates on Space via the base handler (#press)" do
    s = fba_screen
    b = Crysterm::Widget::Button.new parent: s, content: "Go"
    pressed = 0
    b.on(Crysterm::Event::Press) { pressed += 1 }
    b.emit space_key
    pressed.should eq 1
  end

  it "checkable Button toggles on Enter via the base handler" do
    s = fba_screen
    b = Crysterm::Widget::Button.new parent: s, content: "Go", checkable: true
    b.emit enter_key
    b.checked?.should be_true
    b.emit enter_key
    b.checked?.should be_false
  end

  it "ToolButton activates on Space (#press) through its on_keypress super-chain" do
    s = fba_screen
    tb = Crysterm::Widget::ToolButton.new parent: s, content: "T"
    pressed = 0
    tb.on(Crysterm::Event::Press) { pressed += 1 }
    tb.emit space_key
    pressed.should eq 1
  end

  it "CheckBox toggles on Space via the shared #activate hook (#toggle)" do
    s = fba_screen
    cb = Crysterm::Widget::CheckBox.new parent: s, content: "X"
    checks = 0
    cb.on(Crysterm::Event::Check) { checks += 1 }
    cb.emit space_key
    cb.checked?.should be_true
    checks.should eq 1
  end

  it "RadioButton checks (never unchecks) on Enter via #activate → #toggle → #check" do
    s = fba_screen
    rb = Crysterm::Widget::RadioButton.new parent: s, content: "R"
    rb.emit enter_key
    rb.checked?.should be_true
    rb.emit enter_key # radio toggle is check-only; stays checked
    rb.checked?.should be_true
  end

  it "a non-activating key does not activate any member" do
    s = fba_screen
    b = Crysterm::Widget::Button.new parent: s, content: "Go"
    pressed = 0
    b.on(Crysterm::Event::Press) { pressed += 1 }
    b.emit Crysterm::Event::KeyPress.new('a', nil)
    pressed.should eq 0
  end
end
