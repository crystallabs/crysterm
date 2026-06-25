# Example: Crysterm::Layout::Stack
#
# Minimal, self-contained example of a single Stack.
# Run it:     crystal run examples/layout/stack/stack.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "Stack" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  # All three children occupy the full area; only `current` is shown.
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    layout: Crysterm::Layout::Stack.new(current: 1), overflow: :ignore
  3.times do |i|
    Crysterm::Widget::Box.new parent: container,
      content: "{center}page #{i + 1} of 3\n\n(Stack shows current = 1){/center}", parse_tags: true
  end
end
