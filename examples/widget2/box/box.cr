# Example: Crysterm::Widget::Box
#
# Minimal, self-contained example of a single Box.
# Run it:     crystal run examples/widget/box/box.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Box" do |screen|
  screen.stylesheet = "Box { border: solid; background-color: #1a1a2e; color: #e0e0e0; }"
  Crysterm::Widget::Box.new \
    parent: screen, top: "center", left: "center", width: 34, height: 7,
    content: "{center}A Box widget{/center}", parse_tags: true
end
