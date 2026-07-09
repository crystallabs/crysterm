require "./spec_helper"

include Crysterm

private def gb_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def gb_mouse_down(x : Int32, y : Int32)
  Crysterm::Event::Mouse.new(
    Tput::Mouse::Event.new(Tput::Mouse::Action::Down, Tput::Mouse::Button::Left, x, y))
end

# Complements the existing GroupBox toggle spec: a child adopted into an
# *already unchecked* group must come up disabled (the `Adopt` handler), and a
# click on the title row toggles the group.
describe Crysterm::Widget::GroupBox do
  it "disables a child added after the group is unchecked" do
    s = gb_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Opt", checkable: true, width: 30, height: 8
    gb.toggle # uncheck first
    gb.checked?.should be_false

    late = Crysterm::Widget::CheckBox.new parent: gb, top: 0, content: "Late"
    late.state.disabled?.should be_true # Adopt reflected the unchecked state
  end

  it "toggles when the title row is clicked, but not when the body is clicked" do
    s = gb_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Opt", checkable: true,
      top: 0, left: 0, width: 30, height: 8
    s._render
    gb.checked?.should be_true

    # Click on the title row (top edge).
    gb.emit Crysterm::Event::Mouse, gb_mouse_down(gb.aleft + 1, gb.atop).mouse
    gb.checked?.should be_false

    # Click well inside the body must not toggle.
    gb.emit Crysterm::Event::Mouse, gb_mouse_down(gb.aleft + 1, gb.atop + 3).mouse
    gb.checked?.should be_false
  end

  it "restores only the children it disabled when re-checked" do
    s = gb_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Opt", checkable: true, width: 30, height: 8
    child = Crysterm::Widget::CheckBox.new parent: gb, top: 0, content: "Wrap"

    gb.toggle # uncheck => child disabled
    child.state.disabled?.should be_true
    gb.toggle # re-check => child we greyed out returns to normal
    child.state.normal?.should be_true
  end

  it "draws the checkable marker from the Glyphs registry at the effective tier" do
    s = gb_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Opt", checkable: true,
      top: 0, left: 0, width: 30, height: 8
    s._render
    row = (0...30).map { |x| s.lines[gb.atop][gb.aleft + x].char }.join
    row.includes?("[x]").should be_true # Unicode tier: mark falls down to ascii 'x'

    # A tier change *after* construction (a retheme, or the screen's
    # post-probe auto upgrade — widgets are built before `exec` probes) must
    # rebuild the baked marker on the next render.
    s.glyph_tier = Glyphs::Tier::Extended
    s._render
    row = (0...30).map { |x| s.lines[gb.atop][gb.aleft + x].char }.join
    row.includes?("[✓]").should be_true
  end
end
