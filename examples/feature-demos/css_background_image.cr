# DEMO: a CSS `background-image` painted *behind* a widget's text.
#
# `background-image: url(...)` resolves an internal `Widget::Media` background
# layer (`Media.resolve(Content::Background)`). On a Kitty-graphics terminal it
# becomes a true-color image placed *under* the cell grid (negative `z=`), so the
# text renders on top of it; cells with the terminal-default background let the
# image show through, while a cell with an explicit `background-color` hides it.
#
# Backend choice reuses the `image.exclude` config, so excluding `kitty` falls
# back to the next candidate. Only Kitty draws under text today, so on other
# terminals the background simply has no visible effect (the text still shows).
#
# This needs a Kitty-graphics-capable terminal on a real display.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "CSS background-image"

# Style the box entirely through CSS so the whole path (cascade → Style →
# background layer) is exercised. `background-size: cover` fills the box.
s.stylesheet = <<-CSS
  Box.hero {
    background-image: url("#{__DIR__}/../../screenshots/matterhorn.png");
    background-size: cover;
    color: white;
  }
CSS

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}CSS background-image  ·  text composited over a Kitty image{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

box = Widget::Box.new \
  parent: s, top: 1, left: 0, width: "100%", height: "100%-1",
  parse_tags: true, align: "center",
  content: "{bold}Text on top of a background image.{/bold}\n\n" \
           "Empty cells (default background) reveal the image;\n" \
           "this text sits in front of it."
box.add_css_class "hero"

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
