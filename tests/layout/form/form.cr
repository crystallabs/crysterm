# Example: Crysterm::Layout::Form
#
# Minimal, self-contained example of a single Form.
# Run it:     crystal run examples/layout/form/form.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "Form" do |screen|
  screen.stylesheet = "Box { color: #c0caf5; }"
  # Label/field pairs, one per row; a trailing unpaired child spans full width.
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 2, left: 2, width: 50, height: 12,
    layout: Crysterm::Layout::Form.new(label_width: 10, row_gap: 1), overflow: :ignore
  { {"Name:", "Ada Lovelace"}, {"Email:", "ada@example.com"}, {"Role:", "Engineer"} }.each do |label, value|
    Crysterm::Widget::Box.new parent: container, height: 1, content: label
    Crysterm::Widget::Box.new parent: container, height: 1, content: value
  end
  Crysterm::Widget::Box.new parent: container, height: 1,
    content: "{center}[ Submit ]{/center}", parse_tags: true
end
