# Example: Crysterm::Layout::Masonry
#
# Minimal, self-contained example of a single Masonry.
# Run it:     crystal run examples/layout/masonry/masonry.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "Masonry" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    layout: Crysterm::Layout::Masonry.new, overflow: :ignore
  # Varying heights flow into the shortest column — the masonry effect.
  [4, 6, 3, 5, 7, 4, 5, 3].each_with_index do |h, i|
    Crysterm::Widget::Box.new parent: container, width: 16, height: h,
      content: "{center}##{i + 1}{/center}", parse_tags: true
  end
end
