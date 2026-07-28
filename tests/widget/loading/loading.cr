# Example: Crysterm::Widget::Loading
#
# Minimal, self-contained example of a single Loading.
# Run it:     crystal run tests/widget/loading/loading.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Loading" do |window|
  window.stylesheet = "Loading { color: #7dcfff; }"
  # compact: spinner inline with text on one row.
  l = Loading.new parent: window, top: "center", left: "center", width: 30, height: 1,
    compact: true, content: "Loading…"
  Crysterm::WidgetExample.animate_with(l.interval) { l.step }
end
