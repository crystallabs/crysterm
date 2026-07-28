# Example: Crysterm::Widget::Button
#
# Minimal, self-contained example of a single Button.
# Run it:     crystal run tests/widget/button/button.cr
require "../example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run "Button" do |window|
  window.stylesheet = "Button { border: solid; background-color: #394b70; color: #c0caf5; }"
  Button.new \
    parent: window, top: "center", left: "center", width: 22, height: 3,
    content: "{center}Click me{/center}", parse_tags: true
end
