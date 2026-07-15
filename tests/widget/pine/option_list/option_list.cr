# Example: Crysterm::Widget::Pine::OptionList
#
# Minimal, self-contained example of a single OptionList.
# Run it:     crystal run examples/widget/pine/option_list/option_list.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "OptionList" do |screen|
  screen.stylesheet = "Pine::OptionList { border: solid; color: #c0caf5; }"
  ol = Crysterm::Widget::Pine::OptionList.new parent: screen, top: "center", left: "center", width: 64, height: 12, label: " Options "
  ol.options = ([
    Crysterm::Widget::Pine::OptionList::Option.new("line-wrap",
      Crysterm::Widget::Pine::OptionKind::Toggle,
      "Wrap long lines", value: "true"),
    Crysterm::Widget::Pine::OptionList::Option.new("username",
      Crysterm::Widget::Pine::OptionKind::Text,
      "Name shown to others", value: "crysterm"),
    Crysterm::Widget::Pine::OptionList::Option.new("tab-width",
      Crysterm::Widget::Pine::OptionKind::Number,
      "Spaces per tab", value: "4"),
    Crysterm::Widget::Pine::OptionList::Option.new("theme",
      Crysterm::Widget::Pine::OptionKind::Choice,
      "Color theme", value: "dark", allowed: %w[dark light solarized]),
  ])
  ol.focus
end
