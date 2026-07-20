# Example: Crysterm::Widget::Markdown
#
# Minimal, self-contained example of a single Markdown.
# Run it:     crystal run examples/widget/markdown/markdown.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Markdown" do |window|
  window.stylesheet = "Markdown { border: solid; }"
  md = Markdown.new parent: window, top: "center", left: "center", width: 52, height: 14
  md.set_markdown "# Crysterm\n\nA **terminal UI** toolkit in *Crystal*.\n\n- Widgets\n- Layouts\n- Animations\n\n`crystal run examples/hello.cr`"
end
