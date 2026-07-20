# Example: Crysterm::Widget::Pine::FileBrowser
#
# Minimal, self-contained example of a single FileBrowser.
# Run it:     crystal run examples/widget/pine/file_browser/file_browser.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "FileBrowser" do |window|
  window.stylesheet = "Pine::FileBrowser { border: solid; color: #c0caf5; }"
  fb = PineFileBrowser.new \
    parent: window, top: "center", left: "center", width: 46, height: 16,
    cwd: Dir.current, label: " File Browser "
  fb.refresh
  fb.focus
end
