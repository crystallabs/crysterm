require "./spec_helper"

include Crysterm

private def gbr_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Turning off a checkable GroupBox's checkability must re-enable the children it
# had greyed out — otherwise, with the checkbox gone, they're stuck disabled and
# there's no interactive way to recover them.
describe Crysterm::Widget::GroupBox do
  it "re-enables greyed-out children when checkability is turned off" do
    s = gbr_screen
    gb = Crysterm::Widget::GroupBox.new parent: s, title: "Opt", checkable: true, width: 30, height: 8
    child = Crysterm::Widget::CheckBox.new parent: gb, top: 0, content: "Wrap"

    gb.toggle # uncheck => child disabled
    child.state.disabled?.should be_true

    gb.checkable = false
    child.state.disabled?.should be_false
    child.state.normal?.should be_true
  end
end
