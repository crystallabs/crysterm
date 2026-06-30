# Example: Crysterm::Layout::Wrap
#
# Minimal, self-contained example of a single Wrap.
# Run it:     crystal run examples/layout/wrap/wrap.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "Wrap" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    layout: Crysterm::Layout::Wrap.new, overflow: :ignore
  %w[alpha beta gamma delta epsilon zeta eta theta iota].each do |label|
    Crysterm::Widget::Box.new parent: container, width: 13, height: 3,
      content: "{center}#{label}{/center}", parse_tags: true
  end
end
