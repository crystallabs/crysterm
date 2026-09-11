# Example: Crysterm::Widget::Pine::FileBrowser
#
# Minimal, self-contained example of a single FileBrowser.
# Run it:     crystal run tests/widget/pine/file_browser/file_browser.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "FileBrowser" do |window|
  window.stylesheet = "FileBrowser { border: solid; color: #c0caf5; }"
  fb = CW::PineFileBrowser.new \
    parent: window, top: "center", left: "center", width: 46, height: 16,
    cwd: Dir.current, label: " File Browser "
  fb.refresh
  fb.focus
end
