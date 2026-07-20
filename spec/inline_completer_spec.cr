require "./spec_helper"

include Crysterm

# End-to-end: a real `Completer` on a `LineEdit` inside an INLINE window. Proves
# the full widget stack (overlay placement, focus, popup) works unchanged in
# inline mode, and that the rendered popup is offset down to the anchor row.

private def inline_screen(*, height = 10, offset = 0)
  s = Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: height, alternate: false, default_quit_keys: false)
  s.render_row_offset = offset
  s
end

private def build_completer(s, top)
  box = Crysterm::Widget::LineEdit.new parent: s, top: top, left: 4, width: 18, height: 1
  completer = Crysterm::Completer.new %w[Crystal Ruby Rust Python Perl Go]
  completer.attach box
  box.focus
  s.repaint
  box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\0', Tput::Key::Down)
  s.repaint
  {box, completer, completer.@popup.not_nil!}
end

describe "Completer inside an inline window" do
  it "opens the drop-down flush below the field (surface geometry, offset-independent)" do
    s = inline_screen offset: 5
    box, completer, pop = build_completer s, 0

    # Widget geometry lives in surface space, unaffected by the render offset:
    # the popup still sits directly under the field.
    pop.aleft.should eq box.aleft
    pop.atop.should eq box.atop + box.aheight
    completer.open?.should be_true
  end

  it "renders the popup at physical rows shifted by the render offset" do
    s = inline_screen offset: 5
    box, _c, _pop = build_completer s, 0

    # Force a full repaint (a clean re-render diffs to nothing) so the popup's
    # rows are actually emitted this frame.
    s.output.as(IO::Memory).clear
    s.realloc
    s.repaint
    out = s.output.as(IO::Memory).to_s

    # The popup's surface top is box row 1 (top:0 + height 1); on the wire that
    # must land at physical row 1 + offset(5) = 6 (1-based -> "\e[7;").
    surface_top = box.atop + box.aheight
    phys_1based = surface_top + s.render_row_offset + 1
    out.should contain "\e[#{phys_1based};"
    # And nothing rendered at un-offset row 1.
    out.should_not match /\e\[1;\d+H/
  end

  it "commits a selection (completer drives the field as usual)" do
    s = inline_screen offset: 3
    box, completer, _pop = build_completer s, 0
    # Enter accepts the highlighted completion into the field.
    box.emit Crysterm::Event::KeyPress, Crysterm::Event::KeyPress.new('\r', Tput::Key::Enter)
    s.repaint
    box.value.empty?.should be_false
    completer.open?.should be_false
  end
end
