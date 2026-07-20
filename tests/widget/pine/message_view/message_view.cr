# Example: Crysterm::Widget::Pine::MessageView
#
# Minimal, self-contained example of a single MessageView.
# Run it:     crystal run examples/widget/pine/message_view/message_view.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "MessageView" do |window|
  window.stylesheet = "MessageView { border: solid; }"
  PineMessageView.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    from: "alice@example.com", to: "bob@example.com",
    date: "2026-06-24", subject: "Hello from Crysterm",
    body: "This is the message body.\nA Pine-style message view."
end
