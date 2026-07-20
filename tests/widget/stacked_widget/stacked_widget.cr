# Example: Crysterm::Widget::StackedWidget
#
# Minimal, self-contained example of a single StackedWidget.
# Run it:     crystal run examples/widget/stacked_widget/stacked_widget.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "StackedWidget" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  sw = StackedWidget.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  sw.add_widget Widget::Box.new(content: "{center}Page 1 of 3\n\n(StackedWidget shows one page){/center}", parse_tags: true)
  sw.add_widget Widget::Box.new(content: "{center}Page 2{/center}", parse_tags: true)
  sw.current_index = 0
end
