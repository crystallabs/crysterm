# Example: Crysterm::Widget::Question
#
# Minimal, self-contained example of a single Question.
# Run it:     crystal run examples/widget/question/question.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Question" do |window|
  window.stylesheet = "Question { border: solid; color: #c0caf5; }"
  Question.new \
    parent: window, top: "center", left: "center", width: 46, height: 7,
    content: "Delete this file? This cannot be undone."
end
