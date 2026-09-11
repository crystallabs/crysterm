# Example: Crysterm::Widget::Pine::OptionList
#
# Minimal, self-contained example of a single OptionList.
# Run it:     crystal run tests/widget/pine/option_list/option_list.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "OptionList" do |window|
  window.stylesheet = "OptionList { border: solid; color: #c0caf5; }"
  ol = CW::PineOptionList.new parent: window, top: "center", left: "center", width: 64, height: 12, label: " Options "
  ol.options = ([
    CW::PineOptionList::Option.new("line-wrap",
      CT::Widget::Pine::OptionKind::Toggle,
      "Wrap long lines", value: "true"),
    CW::PineOptionList::Option.new("username",
      CT::Widget::Pine::OptionKind::Text,
      "Name shown to others", value: "crysterm"),
    CW::PineOptionList::Option.new("tab-width",
      CT::Widget::Pine::OptionKind::Number,
      "Spaces per tab", value: "4"),
    CW::PineOptionList::Option.new("theme",
      CT::Widget::Pine::OptionKind::Choice,
      "Color theme", value: "dark", allowed: %w[dark light solarized]),
  ])
  ol.focus
end
