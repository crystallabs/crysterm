require "./spec_helper"

include Crysterm

# `Widget::Loading` reads `@frames[0]` at construction (and cycles `@pos` via
# `% frames.size` in `#step`). An empty `frames:` array — a plausible "no frames"
# input — must fall back to the default frames so the widget constructs and
# animates instead of raising `IndexError` (or dividing by zero on a step).

describe "Widget::Loading with an empty frames array" do
  it "constructs without IndexError (falls back to the default frames)" do
    s = headless_screen(20, 10)
    # Must not raise IndexError from `@frames[0]`.
    loading = Crysterm::Widget::Loading.new(parent: s, frames: [] of String)
    loading.frames.should_not be_empty
    loading.icon.content.should eq loading.frames[0]
  end

  it "steps without dividing by zero" do
    s = headless_screen(20, 10)
    loading = Crysterm::Widget::Loading.new(parent: s, frames: [] of String)
    n = loading.frames.size
    loading.step # `% frames.size` would be `% 0` on an empty array
    loading.icon.content.should eq loading.frames[1 % n]
  end
end
