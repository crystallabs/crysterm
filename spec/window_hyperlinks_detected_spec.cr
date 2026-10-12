require "./spec_helper"

include Crysterm

describe "Window#hyperlinks_detected?" do
  it "answers what Auto decides whatever the policy is" do
    w = headless_screen(40, 10)
    begin
      # A headless window writes to an in-memory IO, no tty: Auto says no.
      w.hyperlinks_detected?.should be_false
      w.hyperlinks = AutoToggle::On
      w.hyperlinks?.should be_true
      w.hyperlinks_detected?.should be_false
      w.hyperlinks = AutoToggle::Auto
      w.hyperlinks?.should eq w.hyperlinks_detected?
    ensure
      w.destroy
    end
  end
end
