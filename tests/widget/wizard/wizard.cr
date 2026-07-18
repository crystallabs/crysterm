# Example: Crysterm::Widget::Wizard
#
# Minimal, self-contained example of a single Wizard.
# Run it:     crystal run examples/widget/wizard/wizard.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Wizard" do |screen|
  screen.stylesheet = "Wizard { color: #c0caf5; }"
  wiz = Crysterm::Widget::Wizard.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
  wiz.add_page "Welcome", Crysterm::Widget::Box.new(content: "{center}Welcome to the setup wizard.{/center}", parse_tags: true)
  wiz.add_page "Options", Crysterm::Widget::Box.new(content: "{center}Choose your options.{/center}", parse_tags: true)
  wiz.add_page "Finish", Crysterm::Widget::Box.new(content: "{center}All done!{/center}", parse_tags: true)
end
