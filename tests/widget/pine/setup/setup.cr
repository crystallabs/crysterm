# Example: Crysterm::Widget::Pine::Setup
#
# Minimal, self-contained example of a single Setup.
# Run it:     crystal run examples/widget/pine/setup/setup.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "Setup" do |screen|
  screen.stylesheet = "Pine::Setup { border: solid; color: #c0caf5; }"
  st = Crysterm::Widget::Pine::Setup.new parent: screen, top: "center", left: "center", width: 50, height: 12, label: " Setup "
  st.options = ([
    Crysterm::Widget::Pine::Setup::Option.new("Printer", "Configure printer support", enabled: true),
    Crysterm::Widget::Pine::Setup::Option.new("Newmail", "Notify on new mail", enabled: true),
    Crysterm::Widget::Pine::Setup::Option.new("Threading", "Group messages by thread", enabled: false),
  ])
  st.focus
end
