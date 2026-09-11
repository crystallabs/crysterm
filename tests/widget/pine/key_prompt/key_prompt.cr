# Example: Crysterm::Widget::Pine::KeyPrompt
#
# Minimal, self-contained example of a single KeyPrompt.
# Run it:     crystal run tests/widget/pine/key_prompt/key_prompt.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "KeyPrompt" do |window|
  window.stylesheet = "KeyPrompt { color: #c0caf5; }"
  prompt = CW::PineKeyPrompt.new(
    "Save changes before exiting?",
    [
      CW::PineKeyPrompt::Choice.new("Y", "Yes"),
      CW::PineKeyPrompt::Choice.new("N", "No"),
      CW::PineKeyPrompt::Choice.new("C", "Cancel"),
    ],
    parent: window, bottom: 0, left: 0,
  )
  prompt.focus
end
