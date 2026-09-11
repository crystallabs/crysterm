# Example: Crysterm::Widget::Pine::Compose
#
# Minimal, self-contained example of a single Compose.
# Run it:     crystal run tests/widget/pine/compose/compose.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Compose" do |window|
  window.stylesheet = "Compose { border: solid; }"
  CW::PineCompose.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    content: "{center}Compose{/center}", parse_tags: true
end
