# Example: Crysterm::Widget::FileManager
#
# Minimal, self-contained example of a single FileManager.
# Run it:     crystal run examples/widget/filemanager/filemanager.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "FileManager" do |window|
  window.stylesheet = "FileManager { border: solid; color: #c0caf5; }"
  fm = FileManager.new \
    parent: window, top: "center", left: "center", width: 46, height: 16,
    cwd: "src/widget", label: " src/widget "
  fm.focus
end
