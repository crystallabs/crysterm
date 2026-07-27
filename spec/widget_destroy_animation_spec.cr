require "./spec_helper"

include Crysterm

# Destroying a widget must stop any animation driving it. `#pulse` never ends
# on its own, so without this wired into `Widget#destroy` its fiber would spin
# forever on the detached widget.

describe "Widget#destroy animation cleanup" do
  it "stops a running pulse (a never-ending ticker) on destroy" do
    s = headless_screen(10, 3, default_quit_keys: true)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    anim = b.pulse
    anim.running?.should be_true
    b.destroy
    anim.running?.should be_false
  end

  it "stops a running tint animation on destroy" do
    s = headless_screen(10, 3, default_quit_keys: true)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    anim = b.tint_to 0xff0000, 0.5, duration: 10.seconds
    anim.running?.should be_true
    b.destroy
    anim.running?.should be_false
  end
end
