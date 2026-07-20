# Example: Crysterm::Widget::Pine::KeyPrompt
#
# Minimal, self-contained example of a single KeyPrompt.
# Run it:     crystal run examples/widget/pine/key_prompt/key_prompt.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "KeyPrompt" do |window|
  window.stylesheet = "Pine::KeyPrompt { color: #c0caf5; }"
  prompt = PineKeyPrompt.new(
    "Save changes before exiting?",
    [
      PineKeyPrompt::Choice.new("Y", "Yes"),
      PineKeyPrompt::Choice.new("N", "No"),
      PineKeyPrompt::Choice.new("C", "Cancel"),
    ],
    parent: window, bottom: 0, left: 0,
  )
  prompt.focus
end
