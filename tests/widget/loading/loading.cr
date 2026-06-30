# Example: Crysterm::Widget::Loading
#
# Minimal, self-contained example of a single Loading.
# Run it:     crystal run examples/widget/loading/loading.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "Loading" do |screen|
  screen.stylesheet = "Loading { color: #7dcfff; }"
  # compact: spinner is inline with the text ("⠋ Loading…") on one row.
  l = Crysterm::Widget::Loading.new parent: screen, top: "center", left: "center", width: 30, height: 1,
    compact: true, content: "Loading…"
  Crysterm::WidgetExample.animate_with(l.interval) { l.step }
end
