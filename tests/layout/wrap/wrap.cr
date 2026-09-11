# Example: Crysterm::Layout::Wrap
#
# Minimal, self-contained example of a single Wrap.
# Run it:     crystal run tests/layout/wrap/wrap.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "Wrap" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = CW::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: CT::Layout::Wrap.new
  %w[alpha beta gamma delta epsilon zeta eta theta iota].each do |label|
    CW::Box.new parent: container, width: 13, height: 3,
      content: "{center}#{label}{/center}", parse_tags: true
  end
end
