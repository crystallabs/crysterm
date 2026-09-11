# Example: Crysterm::Widget::Pine::StatusBar
#
# Minimal, self-contained example of a single StatusBar.
# Run it:     crystal run tests/widget/pine/status_bar/status_bar.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "StatusBar" do |window|
  window.stylesheet = "StatusBar { border: solid; }"
  CW::PineStatusBar.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    content: "{center}StatusBar{/center}", parse_tags: true
end
