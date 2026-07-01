require "./spec_helper"

include Crysterm

# Regression: `ButtonGroup#button` must treat `-1` (the "no id" sentinel, as in
# Qt) as un-addressable, even when all members carry it (added without an
# explicit id). Otherwise `button(checked_id)` with nothing checked would
# return the first un-id'd member instead of nil.

private def add_mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

describe Crysterm::ButtonGroup do
  it "never addresses an un-id'd member through the -1 sentinel" do
    s = add_mem_screen
    a = Crysterm::Widget::CheckBox.new parent: s
    b = Crysterm::Widget::CheckBox.new parent: s

    g = Crysterm::ButtonGroup.new
    g.add a # no explicit id -> id is -1
    g.add b # no explicit id -> id is -1

    # Members carry the unset-id sentinel...
    g.id(a).should eq -1
    g.id(b).should eq -1

    # ...yet -1 must not resolve to any of them.
    g.button(-1).should be_nil

    # Nothing checked, so checked_id is the same sentinel; must round-trip to nil.
    g.checked_id.should eq -1
    g.button(g.checked_id).should be_nil

    # A real, explicit id still resolves normally.
    c = Crysterm::Widget::CheckBox.new parent: s
    g.add c, 5
    g.button(5).should eq c
  end
end
