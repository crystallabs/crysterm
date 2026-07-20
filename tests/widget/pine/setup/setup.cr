# Example: Crysterm::Widget::Pine::Setup
#
# Minimal, self-contained example of a single Setup.
# Run it:     crystal run examples/widget/pine/setup/setup.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Setup" do |window|
  window.stylesheet = "Pine::Setup { border: solid; color: #c0caf5; }"
  st = PineSetup.new parent: window, top: "center", left: "center", width: 50, height: 12, label: " Setup "
  st.options = ([
    PineSetup::Option.new("Printer", "Configure printer support", enabled: true),
    PineSetup::Option.new("Newmail", "Notify on new mail", enabled: true),
    PineSetup::Option.new("Threading", "Group messages by thread", enabled: false),
  ])
  st.focus
end
