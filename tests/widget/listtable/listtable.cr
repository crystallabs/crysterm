# Example: Crysterm::Widget::ListTable
#
# Minimal, self-contained example of a single ListTable.
# Run it:     crystal run examples/widget/listtable/listtable.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("ListTable",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 3, dwell: 0.4
    d.key :up, times: 3, dwell: 0.4
  }) do |window|
  window.stylesheet = "ListTable { border: solid; color: #c0caf5; }"
  lt = ListTable.new \
    parent: window, top: "center", left: "center", width: 48, height: 10,
    rows: [["File", "Size", "Modified"], ["crysterm.cr", "2.1K", "Jun 24"], ["widget.cr", "8.4K", "Jun 23"], ["shard.yml", "1.0K", "Jun 24"]]
  lt.focus
end
