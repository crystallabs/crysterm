# Example: Crysterm::Widget::Question
#
# Minimal, self-contained example of a single Question.
# Run it:     crystal run examples/widget/question/question.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Question" do |screen|
  screen.stylesheet = "Question { border: solid; color: #c0caf5; }"
  Crysterm::Widget::Question.new \
    parent: screen, top: "center", left: "center", width: 46, height: 7,
    content: "Delete this file? This cannot be undone."
end
