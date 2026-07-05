require "./spec_helper"

include Crysterm

# `Widget::Loading` reads `@icons[0]` at construction (and cycles `@pos` via
# `% icons.size` in `#step`). An empty `icons:` array — a plausible "no frames"
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

describe "Widget::Loading with an empty icons array" do
  it "constructs without IndexError (falls back to the default frames)" do
    s = lei_screen
    # Before the fix this raised IndexError from `@icons[0]`.
    loading = Crysterm::Widget::Loading.new(parent: s, icons: [] of String)
    loading.icons.should_not be_empty
    loading.icon.content.should eq loading.icons[0]
  end

  it "steps without dividing by zero" do
    s = lei_screen
    loading = Crysterm::Widget::Loading.new(parent: s, icons: [] of String)
    n = loading.icons.size
    loading.step # `% icons.size` would be `% 0` on an empty array
    loading.icon.content.should eq loading.icons[1 % n]
  end
end
