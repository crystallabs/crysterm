# Example: Crysterm::Widget::Fps
#
# Minimal, self-contained example of a single Fps.
# Run it:     crystal run examples/widget/fps/fps.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Fps" do |window|
  window.stylesheet = "Fps { border: solid; color: #9ece6a; }"
  Fps.new parent: window, top: "center", left: "center", width: 30, height: 5
end
