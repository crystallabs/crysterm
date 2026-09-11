# Example: Crysterm::Widget::Pine::MessageIndex
#
# Minimal, self-contained example of a single MessageIndex.
# Run it:     crystal run tests/widget/pine/message_index/message_index.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "MessageIndex" do |window|
  window.stylesheet = "MessageIndex { border: solid; color: #c0caf5; }"
  mi = CW::PineMessageIndex.new parent: window, top: "center", left: "center", width: 56, height: 12, label: " INBOX "
  mi.messages = ([
    CW::PineMessageIndex::Message.new("Ada Lovelace", "Re: Analytical Engine", date: "Jun 24", unread: true),
    CW::PineMessageIndex::Message.new("Grace Hopper", "Compiler patches", date: "Jun 23"),
    CW::PineMessageIndex::Message.new("Linus T.", "Merge window", date: "Jun 22"),
  ])
  mi.focus
end
