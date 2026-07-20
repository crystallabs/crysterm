# Example: Crysterm::Widget::Pine::TextView
#
# Minimal, self-contained example of a single TextView (a generic Pine pager).
# Run it:     crystal run examples/widget/pine/text_view/text_view.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "TextView" do |window|
  window.stylesheet = "TextView { border: solid; }"

  help = <<-TEXT
  {bold}Navigating this interface{/bold}

  Use the Up and Down arrow keys to scroll one line at a time.
  Use PageUp and PageDown to move half a screen at once.
  Press Home to jump to the top, and End to jump to the bottom.

  This is a generic, scrollable text pane. It can show any text:
  help screens, documentation, license notices, or release notes.

  Keep pressing Down to read all the way to the end of this text,
  then press Home to return to the very beginning again.
  TEXT

  view = PineTextView.new \
    content: help,
    parent: window, top: 0, left: 0, width: "100%", height: "100%"
  view.focus
end
