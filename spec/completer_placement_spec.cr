require "./spec_helper"

include Crysterm

# Completer drop-down placement (FORMAL-WIDGETS Part A Piece 3, via
# `Overlay.place_child`): the list is a window-appended child, so its placement
# must subtract the window inset (no drift on a padded window), and it now flips
# above the field when it cannot fit below (a field near the bottom edge),
# rather than spilling off-screen.

private def cp_screen(*, height = 24, padding = nil)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: height, padding: padding, default_quit_keys: false)
end

private def cp_build(s, top)
  box = Crysterm::Widget::LineEdit.new parent: s, top: top, left: 10, width: 18, height: 1
  completer = Crysterm::Completer.new %w[Crystal Ruby Rust Python Perl PHP Go Groovy Java JavaScript Kotlin Lua]
  completer.attach box
  box.focus
  s.repaint
  box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
  s.repaint
  {box, completer, completer.@popup.not_nil!}
end

describe "Completer drop-down placement" do
  it "drops flush below the field with no inset drift on a padded window" do
    s = cp_screen padding: 2
    box, _completer, pop = cp_build s, 5

    pop.aleft.should eq box.aleft
    pop.atop.should eq box.atop + box.aheight
  end

  it "flips above the field when it cannot fit below" do
    # Field near the bottom of a short screen: the list can't fit below, so it
    # must open upward and stay on-screen.
    s = cp_screen height: 14
    box, _completer, pop = cp_build s, 11

    pop.atop.should be < box.atop
    pop.atop.should be >= 0
    (pop.atop + pop.aheight).should be <= s.aheight
  end
end
