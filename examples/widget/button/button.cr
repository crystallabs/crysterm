# Example: Crysterm::Widget::Button
#
# Minimal, self-contained example of a single Button.
# Run it:     crystal run examples/widget/button/button.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Button" do |screen|
  screen.stylesheet = "Button { border: solid; background-color: #394b70; color: #c0caf5; }"
  Crysterm::Widget::Button.new \
    parent: screen, top: "center", left: "center", width: 22, height: 3,
    content: "{center}Click me{/center}", parse_tags: true
end
