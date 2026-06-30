# Example: Crysterm::Widget::Pine::Compose
#
# Minimal, self-contained example of a single Compose.
# Run it:     crystal run examples/widget/pine/compose/compose.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "Compose" do |screen|
  screen.stylesheet = "Compose { border: solid; }"
  Crysterm::Widget::Pine::Compose.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    content: "{center}Compose{/center}", parse_tags: true
end
