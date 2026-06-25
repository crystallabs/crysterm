# Example: Crysterm::Widget::RadioSet
#
# Minimal, self-contained example of a single RadioSet.
# Run it:     crystal run examples/widget/radioset/radioset.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("RadioSet",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.4
    d.key :space, dwell: 0.5                 # check Small (focused)
    d.key :tab; d.key :space, dwell: 0.5     # → Medium
    d.key :tab; d.key :space, dwell: 0.5     # → Large
    d.key :backtab; d.key :space, dwell: 0.6 # back to Medium (initial)
  }) do |screen|
  screen.stylesheet = "RadioSet { border: solid; } RadioButton { color: #c0caf5; }"
  rs = Crysterm::Widget::RadioSet.new parent: screen, top: "center", left: "center", width: 28, height: 7, label: " Size "
  btns = %w[Small Medium Large].map_with_index do |t, i|
    Crysterm::Widget::RadioButton.new parent: rs, top: i, left: 1, content: t, checked: i == 1
  end
  btns.first.focus
end
