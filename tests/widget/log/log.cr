# Example: Crysterm::Widget::Log
#
# Minimal, self-contained example of a single Log.
# Run it:     crystal run examples/widget/log/log.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Log" do |window|
  window.stylesheet = "Log { border: solid; color: #9ece6a; }"
  log = Widget::Log.new parent: window, top: "center", left: "center", width: 46, height: 9
  ["system started", "loading config", "ready", "request handled"].each { |l| log.add l }
end
