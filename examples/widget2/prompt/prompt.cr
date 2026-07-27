# Example: Crysterm::Widget::Prompt
#
# Minimal, self-contained example of a single Prompt.
# Run it:     crystal run examples/widget/prompt/prompt.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Prompt" do |screen|
  screen.stylesheet = "Prompt { border: solid; color: #c0caf5; }"
  Crysterm::Widget::Prompt.new \
    parent: screen, top: "center", left: "center", width: 46, height: 7,
    content: "What is your name?"
end
