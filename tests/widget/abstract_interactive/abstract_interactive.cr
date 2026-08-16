# Example: Crysterm::Widget::AbstractInteractive
#
# Minimal, self-contained example of a single AbstractInteractive.
# Run it:     crystal run tests/widget/abstract_interactive/abstract_interactive.cr
require "../example"

include Crysterm

Crysterm::WidgetExample.run "AbstractInteractive" do |window|
  window.stylesheet = "AbstractInteractive { border: solid; color: #c0caf5; background-color: #1f2335; }"
  Widget::AbstractInteractive.new \
    parent: window, top: "center", left: "center", width: 44, height: 3,
    content: "AbstractInteractive — base of the text widgets"
end
