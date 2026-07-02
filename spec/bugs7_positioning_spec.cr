require "./spec_helper"

include Crysterm

# Regression spec for the BUGS7 completer-positioning fix: a top-level widget's
# `left`/`top` are relative to the window's *content* origin
# (`aleft == window.ileft + left`), but `Completer#position` set the popup's
# `left`/`top` to the widget's absolute `aleft`/`atop`. On a padded/bordered
# window that double-counted the inset and shoved the popup right/down. The fix
# subtracts the window insets.

private def padded_window(w = 30, h = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, padding: 1)
end

describe "BUGS7 completer popup position accounts for window insets" do
  it "places the popup under the box's content-relative origin, not shifted by padding" do
    s = padded_window
    s.ileft.should be > 0 # padded, so the inset actually matters
    s.itop.should be > 0

    input = Widget::LineEdit.new parent: s, top: 2, left: 3, width: 10, height: 1
    comp = Crysterm::Completer.new ["hello", "help", "helm"]
    comp.attach input
    s._render
    input.focus

    # Down opens the drop-down (browse mode); this runs `position`.
    down = Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Down)
    input.emit Crysterm::Event::KeyPress, down
    comp.open?.should be_true

    pop = s.children.find! { |c| c.is_a?(Widget::List) }
    # Content-relative coordinates: subtracting the window inset undoes the
    # double-count. Pre-fix these equalled the absolute `aleft`/`atop`.
    pop.left.should eq input.aleft - s.ileft
    pop.top.should eq input.atop + input.aheight - s.itop
  ensure
    comp.try &.detach
    s.try &.destroy
  end
end
