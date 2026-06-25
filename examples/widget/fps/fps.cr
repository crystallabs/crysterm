# Example: Crysterm::Widget::Fps
#
# Minimal, self-contained example of a single Fps.
# Run it:     crystal run examples/widget/fps/fps.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Fps" do |screen|
  screen.stylesheet = "Fps { border: solid; color: #9ece6a; }"
  Crysterm::Widget::Fps.new parent: screen, top: "center", left: "center", width: 30, height: 5
end
