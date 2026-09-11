# Example: Crysterm::Layout::VBox
#
# Minimal, self-contained example of a single VBox.
# Run it:     crystal run tests/layout/vbox/vbox.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "VBox" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = CW::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: CT::Layout::VBox.new(spacing: 1)
  %w[Top Middle Middle Bottom].each do |label|
    CW::Box.new parent: container, content: "{center}#{label}{/center}", parse_tags: true
  end
end
