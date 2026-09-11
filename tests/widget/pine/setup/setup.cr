# Example: Crysterm::Widget::Pine::Setup
#
# Minimal, self-contained example of a single Setup.
# Run it:     crystal run tests/widget/pine/setup/setup.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "Setup" do |window|
  window.stylesheet = "Setup { border: solid; color: #c0caf5; }"
  st = CW::PineSetup.new parent: window, top: "center", left: "center", width: 50, height: 12, label: " Setup "
  st.options = ([
    CW::PineSetup::Option.new("Printer", "Configure printer support", enabled: true),
    CW::PineSetup::Option.new("Newmail", "Notify on new mail", enabled: true),
    CW::PineSetup::Option.new("Threading", "Group messages by thread", enabled: false),
  ])
  st.focus
end
