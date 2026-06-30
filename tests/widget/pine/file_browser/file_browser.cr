# Example: Crysterm::Widget::Pine::FileBrowser
#
# Minimal, self-contained example of a single FileBrowser.
# Run it:     crystal run examples/widget/pine/file_browser/file_browser.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "FileBrowser" do |screen|
  screen.stylesheet = "Pine::FileBrowser { border: solid; color: #c0caf5; }"
  fb = Crysterm::Widget::Pine::FileBrowser.new \
    parent: screen, top: "center", left: "center", width: 46, height: 16,
    cwd: Dir.current, label: " File Browser "
  fb.refresh
  fb.focus
end
