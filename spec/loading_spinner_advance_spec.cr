require "./spec_helper"

include Crysterm

# `Loading#step` used to paint `icons[@pos]` before advancing `@pos`. Since the
# icon already shows `icons[0]` (set in `initialize`), the first animation tick
# re-painted that same frame, freezing the spinner on frame 0 for two intervals.
# Stepping `@pos` first makes every tick, including the first, advance a frame.
describe Crysterm::Widget::Loading do
  it "advances to the next spinner frame on the first step (no duplicated first frame)" do
    screen = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 20, height: 10,
    )
    loading = Crysterm::Widget::Loading.new(parent: screen, icons: ["a", "b", "c", "d"])

    # Starts on the first frame.
    loading.icon.content.should eq "a"

    # First step must move to the next frame, not redisplay the first.
    loading.step
    loading.icon.content.should eq "b"

    loading.step
    loading.icon.content.should eq "c"

    loading.step
    loading.icon.content.should eq "d"

    # Wraps back to the start after the last frame.
    loading.step
    loading.icon.content.should eq "a"
  end
end
