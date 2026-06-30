# Example: Crysterm::Widget::Pine::ListSelect
#
# Minimal, self-contained example of a single multi-select ListSelect.
# Run it:     crystal run examples/widget/pine/list_select/list_select.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "ListSelect" do |screen|
  screen.stylesheet = "Pine::ListSelect { border: solid; color: #c0caf5; }"
  items = ["Apricot", "Banana", "Cherry", "Date", "Elderberry"]
  ls = Crysterm::Widget::Pine::ListSelect(String).new(
    items,
    label: ->(s : String) { s },
    multi: true,
    parent: screen,
    top: "center", left: "center", width: 40, height: 9)
  ls.focus
end
