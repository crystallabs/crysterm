# Example: Crysterm::Widget::FileManager
#
# Minimal, self-contained example of a single FileManager.
# Run it:     crystal run examples/widget/filemanager/filemanager.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "FileManager" do |screen|
  screen.stylesheet = "FileManager { border: solid; color: #c0caf5; }"
  fm = Crysterm::Widget::FileManager.new \
    parent: screen, top: "center", left: "center", width: 46, height: 16,
    cwd: "src/widget", label: " src/widget "
  fm.focus
end
