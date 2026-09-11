# Example: Crysterm::Layout::HBox
#
# Minimal, self-contained example of a single HBox.
# Run it:     crystal run tests/layout/hbox/hbox.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "HBox" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = CW::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: CT::Layout::HBox.new(spacing: 1)
  # Children given no width share the row equally (align: stretch fills height).
  %w[Left Middle Middle Right].each do |label|
    CW::Box.new parent: container, content: "{center}#{label}{/center}", parse_tags: true
  end
end
