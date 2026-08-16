require "./spec_helper"

include Crysterm

# The `:hover` runtime producer: real mouse movement drives
# `WidgetState::Hovered`, so `:hover` CSS rules apply without any manual
# `state=` poking. Hover ranks below Focused/Selected/Disabled in the
# single-valued state model.

private def hover_move(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, y)
end

# A screen with a `park` widget holding focus, so the button under test rests
# at `Normal` (a sole focusable widget would auto-focus and rest at `Focused`).
private def hover_rig
  s = headless_screen(20, 6)
  park = Widget::Button.new parent: s, top: 5, left: 12, width: 6, height: 1, text: "park"
  b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
  park.focus
  s.repaint
  {s, b, park}
end

describe ":hover runtime state" do
  it "enters Hovered on mouse-over and restores Normal on leave" do
    s, b, _park = hover_rig
    b.state.normal?.should be_true

    hover_move s, b.aleft, b.atop
    b.state.hovered?.should be_true
    hover_move s, 0, 3 # off the widget
    b.state.normal?.should be_true
  end

  it "applies :hover CSS from real mouse movement" do
    s, b, _park = hover_rig
    s.stylesheet = "Button { background-color: #001122; } Button:hover { background-color: #a0e0ff; }"
    s.repaint
    b.style.bg.should eq 0x001122

    hover_move s, b.aleft, b.atop
    b.style.bg.should eq 0xa0e0ff
    hover_move s, 0, 3
    b.style.bg.should eq 0x001122
  end

  it "does not demote a focused widget to Hovered" do
    s, b, _park = hover_rig
    b.focus
    b.state.focused?.should be_true

    hover_move s, b.aleft, b.atop
    b.state.focused?.should be_true
    hover_move s, 0, 3
    b.state.focused?.should be_true # leaving must not clobber focus either
  end

  it "falls back to Hovered (not Normal) when blurred under the pointer" do
    s, b, park = hover_rig
    hover_move s, b.aleft, b.atop
    b.focus
    b.state.focused?.should be_true

    park.focus # blur b while the pointer still rests on it
    b.state.hovered?.should be_true
  end

  it "falls back to Hovered after a programmatic un-press under the pointer" do
    s, b, _park = hover_rig
    hover_move s, b.aleft, b.atop
    b.state.hovered?.should be_true

    b.down = true
    b.state.selected?.should be_true
    b.down = false
    b.state.hovered?.should be_true # unfocused, still under the pointer
  end

  it "presses from hover and returns focus on release (full mouse gesture)" do
    s, b, _park = hover_rig
    hover_move s, b.aleft, b.atop
    b.state.hovered?.should be_true

    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    b.state.selected?.should be_true
    s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::Left, b.aleft, b.atop)
    b.state.focused?.should be_true # click focused it; focus outranks hover
  end
end
