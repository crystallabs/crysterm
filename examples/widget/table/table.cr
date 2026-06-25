# Example: Crysterm::Widget::Table
#
# Minimal, self-contained example of a single Table.
# Run it:     crystal run examples/widget/table/table.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("Table",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 3, dwell: 0.4
    d.key :up, times: 3, dwell: 0.4
  }) do |screen|
  screen.stylesheet = "Table { border: solid; color: #c0caf5; }"
  Crysterm::Widget::Table.new \
    parent: screen, top: "center", left: "center", width: 48, height: 10,
    rows: [["Name", "Role", "Commits"], ["Ada", "Engineer", "128"], ["Linus", "Maintainer", "942"], ["Grace", "Architect", "377"]]
end
