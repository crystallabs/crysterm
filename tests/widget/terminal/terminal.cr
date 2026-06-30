# Example: Crysterm::Widget::Terminal
#
# Minimal, self-contained example of a single Terminal.
# Run it:     crystal run examples/widget/terminal/terminal.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Terminal" do |screen|
  screen.stylesheet = "Terminal { border: solid; }"
  Crysterm::Widget::Terminal.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    content: "{center}Terminal{/center}", parse_tags: true
end
