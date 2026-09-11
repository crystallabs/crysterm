# Example: Crysterm::Layout::Stack
#
# Minimal, self-contained example of a single Stack.
# Run it:     crystal run tests/layout/stack/stack.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "Stack" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  # All three children occupy the full area; only `current` is shown.
  container = CW::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: CT::Layout::Stack.new(current_index: 1)
  3.times do |i|
    CW::Box.new parent: container,
      content: "{center}page #{i + 1} of 3\n\n(Stack shows current = 1){/center}", parse_tags: true
  end
end
