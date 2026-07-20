# Example: Crysterm::Widget::Pine::MessageIndex
#
# Minimal, self-contained example of a single MessageIndex.
# Run it:     crystal run examples/widget/pine/message_index/message_index.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "MessageIndex" do |window|
  window.stylesheet = "Pine::MessageIndex { border: solid; color: #c0caf5; }"
  mi = PineMessageIndex.new parent: window, top: "center", left: "center", width: 56, height: 12, label: " INBOX "
  mi.messages = ([
    PineMessageIndex::Message.new("Ada Lovelace", "Re: Analytical Engine", date: "Jun 24", unread: true),
    PineMessageIndex::Message.new("Grace Hopper", "Compiler patches", date: "Jun 23"),
    PineMessageIndex::Message.new("Linus T.", "Merge window", date: "Jun 22"),
  ])
  mi.focus
end
