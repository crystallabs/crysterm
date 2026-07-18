require "./spec_helper"

include Crysterm

# `Widget::Loading` reads `@frames[0]` at construction (and cycles `@pos` via
# `% frames.size` in `#step`). An empty `frames:` array — a plausible "no frames"
# input — made the constructor raise `IndexError` (and would divide by zero on
# a step). An empty array now falls back to the default frames, so the widget
# constructs and animates instead of crashing.

private def lei_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 20,
    height: 10,
    default_quit_keys: false)
end

describe "Widget::Loading with an empty frames array" do
  it "constructs without IndexError (falls back to the default frames)" do
    s = lei_screen
    # Before the fix this raised IndexError from `@frames[0]`.
    loading = Crysterm::Widget::Loading.new(parent: s, frames: [] of String)
    loading.frames.should_not be_empty
    loading.icon.content.should eq loading.frames[0]
  end

  it "steps without dividing by zero" do
    s = lei_screen
    loading = Crysterm::Widget::Loading.new(parent: s, frames: [] of String)
    n = loading.frames.size
    loading.step # `% frames.size` would be `% 0` on an empty array
    loading.icon.content.should eq loading.frames[1 % n]
  end
end
