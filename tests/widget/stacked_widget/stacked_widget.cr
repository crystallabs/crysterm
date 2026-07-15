# Example: Crysterm::Widget::StackedWidget
#
# Minimal, self-contained example of a single StackedWidget.
# Run it:     crystal run examples/widget/stacked_widget/stacked_widget.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "StackedWidget" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  sw = Crysterm::Widget::StackedWidget.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
  sw.add_page Crysterm::Widget::Box.new(content: "{center}Page 1 of 3\n\n(StackedWidget shows one page){/center}", parse_tags: true)
  sw.add_page Crysterm::Widget::Box.new(content: "{center}Page 2{/center}", parse_tags: true)
  sw.current_index = 0
end
