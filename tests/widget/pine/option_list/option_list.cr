# Example: Crysterm::Widget::Pine::OptionList
#
# Minimal, self-contained example of a single OptionList.
# Run it:     crystal run examples/widget/pine/option_list/option_list.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "OptionList" do |window|
  window.stylesheet = "Pine::OptionList { border: solid; color: #c0caf5; }"
  ol = PineOptionList.new parent: window, top: "center", left: "center", width: 64, height: 12, label: " Options "
  ol.options = ([
    PineOptionList::Option.new("line-wrap",
      Widget::Pine::OptionKind::Toggle,
      "Wrap long lines", value: "true"),
    PineOptionList::Option.new("username",
      Widget::Pine::OptionKind::Text,
      "Name shown to others", value: "crysterm"),
    PineOptionList::Option.new("tab-width",
      Widget::Pine::OptionKind::Number,
      "Spaces per tab", value: "4"),
    PineOptionList::Option.new("theme",
      Widget::Pine::OptionKind::Choice,
      "Color theme", value: "dark", allowed: %w[dark light solarized]),
  ])
  ol.focus
end
