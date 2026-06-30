# Example: Crysterm::Widget::Pine::KeyPrompt
#
# Minimal, self-contained example of a single KeyPrompt.
# Run it:     crystal run examples/widget/pine/key_prompt/key_prompt.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "KeyPrompt" do |screen|
  screen.stylesheet = "Pine::KeyPrompt { color: #c0caf5; }"
  prompt = Crysterm::Widget::Pine::KeyPrompt.new(
    "Save changes before exiting?",
    [
      Crysterm::Widget::Pine::KeyPrompt::Choice.new("Y", "Yes"),
      Crysterm::Widget::Pine::KeyPrompt::Choice.new("N", "No"),
      Crysterm::Widget::Pine::KeyPrompt::Choice.new("C", "Cancel"),
    ],
    parent: screen, bottom: 0, left: 0,
  )
  prompt.focus
end
