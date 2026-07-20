# Example: Crysterm::Widget::Splitter
#
# Minimal, self-contained example of a single Splitter.
# Run it:     crystal run examples/widget/splitter/splitter.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Splitter" do |window|
  window.stylesheet = "Splitter { border: solid; } .divider { background-color: #7aa2f7; } Box { color: #c0caf5; }"
  sp = Splitter.new parent: window, top: 0, left: 0, width: "100%", height: "100%", orientation: :horizontal
  sp.add_widget Widget::Box.new(content: "{center}Left pane{/center}", parse_tags: true)
  sp.add_widget Widget::Box.new(content: "{center}Right pane{/center}", parse_tags: true)
end
