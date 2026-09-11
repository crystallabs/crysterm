# Example: Crysterm::Widget::Pine::ListSelect
#
# Minimal, self-contained example of a single multi-select ListSelect.
# Run it:     crystal run tests/widget/pine/list_select/list_select.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "ListSelect" do |window|
  window.stylesheet = "ListSelect { border: solid; color: #c0caf5; }"
  items = ["Apricot", "Banana", "Cherry", "Date", "Elderberry"]
  ls = CW::PineListSelect(String).new(
    items,
    label: ->(s : String) { s },
    multi: true,
    parent: window,
    top: "center", left: "center", width: 40, height: 9)
  ls.focus
end
