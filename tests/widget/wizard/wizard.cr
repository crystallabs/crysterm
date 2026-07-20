# Example: Crysterm::Widget::Wizard
#
# Minimal, self-contained example of a single Wizard.
# Run it:     crystal run examples/widget/wizard/wizard.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Wizard" do |window|
  window.stylesheet = "Wizard { color: #c0caf5; }"
  wiz = Wizard.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  wiz.add_page "Welcome", Widget::Box.new(content: "{center}Welcome to the setup wizard.{/center}", parse_tags: true)
  wiz.add_page "Options", Widget::Box.new(content: "{center}Choose your options.{/center}", parse_tags: true)
  wiz.add_page "Finish", Widget::Box.new(content: "{center}All done!{/center}", parse_tags: true)
end
