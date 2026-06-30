# Example: Crysterm::Widget::Log
#
# Minimal, self-contained example of a single Log.
# Run it:     crystal run examples/widget/log/log.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Log" do |screen|
  screen.stylesheet = "Log { border: solid; color: #9ece6a; }"
  log = Crysterm::Widget::Log.new parent: screen, top: "center", left: "center", width: 46, height: 9
  ["system started", "loading config", "ready", "request handled"].each { |l| log.add l }
end
