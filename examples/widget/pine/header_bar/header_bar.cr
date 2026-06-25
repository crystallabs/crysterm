# Example: Crysterm::Widget::Pine::HeaderBar
#
# Minimal, self-contained example of a single HeaderBar.
# Run it:     crystal run examples/widget/pine/header_bar/header_bar.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "HeaderBar" do |screen|
  screen.stylesheet = "Pine::HeaderBar { color: #1a1a2e; background-color: #7aa2f7; }"
  Crysterm::Widget::Pine::HeaderBar.new \
    parent: screen, top: 0, left: 0,
    title_content: "PINE 4.0", section_content: "MESSAGE INDEX",
    info_content: "Folder: INBOX  12 Messages"
end
