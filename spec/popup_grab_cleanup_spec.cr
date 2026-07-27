require "./spec_helper"

include Crysterm

# `Mixin::Popup#teardown_popup_on_destroy` must release the screen's modal grab
# when a popup-owning widget is destroyed while still open. Otherwise the dead
# widget lingers in `Window#@grabs`, keeping `#grabbing?` true forever and
# routing later mouse presses through `grab_contains?` on a destroyed widget.
describe Crysterm::Mixin::Popup do
  it "releases the modal grab when destroyed while open" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, options: ["a", "b"]
    cb.show_popup
    cb.open?.should be_true
    s.popup_grab_active?.should be_true

    cb.destroy

    # The grab must be gone even though `#close` was never called.
    s.popup_grab_active?.should be_false
  end

  it "leaves the grab untouched when destroyed while closed" do
    s = headless_screen(80, 24)
    cb = Crysterm::Widget::ComboBox.new parent: s, options: ["a", "b"]
    cb.open?.should be_false
    s.popup_grab_active?.should be_false

    cb.destroy
    s.popup_grab_active?.should be_false
  end
end
