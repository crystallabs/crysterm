# Example: Crysterm::Widget::FileManager
#
# Minimal, self-contained example of a single FileManager.
# Run it:     crystal run tests/widget/filemanager/filemanager.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "FileManager" do |window|
  window.stylesheet = "FileManager { border: solid; color: #c0caf5; }"
  fm = CW::FileManager.new \
    parent: window, top: "center", left: "center", width: 46, height: 16,
    cwd: "src/widget", label: " src/widget "
  fm.focus
end
