# Example: Crysterm::Layout::Form
#
# Minimal, self-contained example of a single Form.
# Run it:     crystal run tests/layout/form/form.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "Form" do |window|
  window.stylesheet = "Box { color: #c0caf5; }"
  # Label/field pairs, one per row; a trailing unpaired child spans full width.
  container = CW::Box.new \
    parent: window, top: 2, left: 2, width: 50, height: 12,
    layout: CT::Layout::Form.new(label_width: 10, vertical_spacing: 1)
  { {"Name:", "Ada Lovelace"}, {"Email:", "ada@example.com"}, {"Role:", "Engineer"} }.each do |label, value|
    CW::Box.new parent: container, height: 1, content: label
    CW::Box.new parent: container, height: 1, content: value
  end
  CW::Box.new parent: container, height: 1,
    content: "{center}[ Submit ]{/center}", parse_tags: true
end
