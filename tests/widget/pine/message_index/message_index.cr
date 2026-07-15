# Example: Crysterm::Widget::Pine::MessageIndex
#
# Minimal, self-contained example of a single MessageIndex.
# Run it:     crystal run examples/widget/pine/message_index/message_index.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "MessageIndex" do |screen|
  screen.stylesheet = "Pine::MessageIndex { border: solid; color: #c0caf5; }"
  mi = Crysterm::Widget::Pine::MessageIndex.new parent: screen, top: "center", left: "center", width: 56, height: 12, label: " INBOX "
  mi.messages = ([
    Crysterm::Widget::Pine::MessageIndex::Message.new("Ada Lovelace", "Re: Analytical Engine", date: "Jun 24", unread: true),
    Crysterm::Widget::Pine::MessageIndex::Message.new("Grace Hopper", "Compiler patches", date: "Jun 23"),
    Crysterm::Widget::Pine::MessageIndex::Message.new("Linus T.", "Merge window", date: "Jun 22"),
  ])
  mi.focus
end
