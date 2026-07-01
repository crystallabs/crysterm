require "./spec_helper"

include Crysterm

# `Mixin::SectionedField` drives section selection off `section_at(x)`, which
# must return `nil` when the pointer is off the field (`select_section_at`
# then leaves the active section untouched). `TimeEdit`'s `section_at` only
# bounded the left edge (`col < 0`), so a click past the `HH:MM:SS` text fell
# through `(col // 3).clamp` to the last section, wrongly selecting seconds —
# easily hit since fixed-width controls (`@resizable = false`) have trailing
# space. Fix: bound the right edge to the text width.
private def te_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def te_down(s, te, col)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left,
    te.aleft + col, te.atop)
end

describe "TimeEdit#section_at off-field clicks" do
  it "ignores a click past the text instead of selecting the last section" do
    s = te_screen
    # Width 20 leaves trailing space after the 8-column "HH:MM:SS" text.
    te = Crysterm::Widget::TimeEdit.new parent: s, top: 0, left: 0, width: 20, height: 1,
      time: Time.utc(2020, 1, 1, 10, 20, 30)
    s.render

    # Opens on the hour section (highlighted reverse).
    te.content.should eq "{reverse}10{/reverse}:20:30"

    # Click past the text (col 12, field ends at col 7): stays on the hour.
    te_down s, te, 12
    te.content.should eq "{reverse}10{/reverse}:20:30"

    # In-field click on the minute column still selects it.
    te_down s, te, 3
    te.content.should eq "10:{reverse}20{/reverse}:30"
  end
end
