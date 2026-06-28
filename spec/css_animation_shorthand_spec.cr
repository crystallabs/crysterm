require "./spec_helper"

include Crysterm

# Focused specs for the CSS `animation` shorthand parser
# (`Crysterm::CSS::Properties.apply`). Per the CSS grammar the shorthand may
# carry *two* `<time>` values — the first is `animation-duration`, the second is
# `animation-delay`. Crysterm has no animation-delay, so the second time must be
# ignored, NOT folded back onto the duration. The parser used to assign the
# duration from every time-valued token, so a delay clobbered the real duration:
# `slidein 3s ease-in 1s infinite` ran at the 1s delay instead of its 3s
# duration.
describe "CSS animation shorthand" do
  it "takes the first <time> as the duration (a single time value)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "animation", "pulse 2s linear infinite")
    spec = s.animation.not_nil!
    spec.name.should eq "pulse"
    spec.duration.should eq 2.seconds
    spec.iterations.should be_nil # infinite
  end

  it "keeps the duration when a delay (second <time>) follows" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "animation", "slidein 3s ease-in 1s infinite")
    spec = s.animation.not_nil!
    # The 1s is the delay, which Crysterm ignores — the duration stays 3s rather
    # than being overwritten by the delay.
    spec.duration.should eq 3.seconds
    spec.iterations.should be_nil
  end

  it "keeps the duration regardless of where the delay sits in the value" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "animation", "go 500ms 200ms 3 alternate")
    spec = s.animation.not_nil!
    spec.duration.should eq 500.milliseconds
    spec.iterations.should eq 3
    spec.alternate.should be_true
  end

  it "still parses a bare integer after the duration as the iteration count" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "animation", "go 0.15s linear 1")
    spec = s.animation.not_nil!
    spec.duration.should eq 0.15.seconds
    spec.iterations.should eq 1
  end
end
