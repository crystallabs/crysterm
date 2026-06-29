require "./spec_helper"

include Crysterm

# `Loading#step` used to paint `icons[@pos]` *before* advancing `@pos`. Because
# the icon already shows `icons[0]` (set in `initialize`), the very first
# animation tick re-painted that same first frame, so the spinner sat frozen on
# frame 0 for two intervals before it began to move. Stepping `@pos` first makes
# each tick — including the first — advance to a new frame.
describe Crysterm::Widget::Loading do
  it "advances to the next spinner frame on the first step (no duplicated first frame)" do
    screen = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 20, height: 10,
    )
    loading = Crysterm::Widget::Loading.new(parent: screen, icons: ["a", "b", "c", "d"])

    # The widget starts on the first frame.
    loading.icon.content.should eq "a"

    # The first step must move to the next frame, not redisplay the first.
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
