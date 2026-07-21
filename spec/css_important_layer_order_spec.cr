require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def rgb(name)
  Crysterm::Colors.convert(name).to_i32
end

# Per the CSS cascade, `!important` reverses `@layer` priority: among important
# declarations an earlier layer beats a later one, and unlayered important is
# weakest of all — the opposite of normal declarations. See `Cascade#entry_key`.
describe "CSS !important @layer ordering" do
  it "lets an important rule in an earlier layer beat a later layer" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = <<-CSS
      @layer base, theme;
      @layer theme { Box { color: green !important; } }
      @layer base  { Box { color: red !important; } }
      CSS
    screen.apply_stylesheet
    # `base` is declared before `theme`; for !important the earlier layer wins
    # (reverse of the normal-declaration case).
    box.styles.normal.fg.should eq rgb("red")
  end

  it "makes an unlayered important rule the weakest, beaten by any layered one" do
    screen = headless_screen
    box = Widget::Box.new
    screen.append box

    screen.stylesheet = <<-CSS
      @layer theme { Box { color: green !important; } }
      Box { color: orange !important; }
      CSS
    screen.apply_stylesheet
    # Unlayered important is lowest priority, so layered `theme` wins — the
    # mirror image of unlayered normal declarations, which beat every layer.
    box.styles.normal.fg.should eq rgb("green")
  end
end
