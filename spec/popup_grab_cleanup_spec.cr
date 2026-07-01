require "./spec_helper"

include Crysterm

private def popup_mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# `Mixin::Popup#teardown_popup_on_destroy` must release the screen's modal grab
# when a popup-owning widget is destroyed while still open. Otherwise the dead
# widget lingers in `Window#@grabs`, keeping `#grabbing?` true forever and
# routing later mouse presses through `grab_contains?` on a destroyed widget.
describe Crysterm::Mixin::Popup do
  it "releases the modal grab when destroyed while open" do
    s = popup_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, options: ["a", "b"]
    cb.open
    cb.open?.should be_true
    s.grabbing?.should be_true

    cb.destroy

    # The grab must be gone even though `#close` was never called.
    s.grabbing?.should be_false
  end

  it "leaves the grab untouched when destroyed while closed" do
    s = popup_mem_screen
    cb = Crysterm::Widget::ComboBox.new parent: s, options: ["a", "b"]
    cb.open?.should be_false
    s.grabbing?.should be_false

    cb.destroy
    s.grabbing?.should be_false
  end
end
