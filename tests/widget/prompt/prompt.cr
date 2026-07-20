# Example: Crysterm::Widget::Prompt
#
# Minimal, self-contained example of a single Prompt.
# Run it:     crystal run examples/widget/prompt/prompt.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Prompt" do |window|
  window.stylesheet = "Prompt { border: solid; color: #c0caf5; }"
  Prompt.new \
    parent: window, top: "center", left: "center", width: 46, height: 7,
    content: "What is your name?"
end
