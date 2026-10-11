require "./spec_helper"

include Crysterm

# `Window#mouse_policy`: with a policy set, mouse reporting follows its
# answer for the focused widget, re-asked on every focus change and on
# `#apply_mouse_policy`; without one the app's own enable/disable stands.

private def stage
  s = headless_screen(40, 6)
  a = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 20, height: 1
  b = Widget::LineEdit.new parent: s, top: 2, left: 0, width: 20, height: 1
  s.repaint
  {s, a, b}
end

describe "Window#mouse_policy" do
  it "turns the mouse on and off as focus moves between widgets" do
    s, a, b = stage
    a.focus
    s.mouse_policy = ->(w : Widget?) { w.same?(a) }
    s.mouse_enabled?.should be_true
    b.focus
    s.mouse_enabled?.should be_false
    a.focus
    s.mouse_enabled?.should be_true
    s.destroy
  end

  it "applies when set, and re-applies on apply_mouse_policy" do
    s, a, _ = stage
    a.focus
    s.enable_mouse
    s.mouse_policy = ->(_w : Widget?) { false }
    s.mouse_enabled?.should be_false
    serve = false
    s.mouse_policy = ->(_w : Widget?) { serve }
    s.mouse_enabled?.should be_false
    serve = true
    s.apply_mouse_policy
    s.mouse_enabled?.should be_true
    s.destroy
  end

  it "leaves the mouse alone without a policy" do
    s, a, b = stage
    s.enable_mouse
    a.focus
    b.focus
    s.mouse_enabled?.should be_true
    s.mouse_policy = ->(_w : Widget?) { false }
    s.mouse_enabled?.should be_false
    s.mouse_policy = nil
    a.focus
    s.mouse_enabled?.should be_false
    s.destroy
  end

  it "asks with nil when no widget has focus" do
    s, a, _ = stage
    s.release_focus # the window had focused the first widget on its own
    seen = [] of Widget?
    s.mouse_policy = ->(w : Widget?) { seen << w; true }
    seen.last.should be_nil
    a.focus
    seen.last.should be a
    s.destroy
  end
end
