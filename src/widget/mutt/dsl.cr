module Crysterm
  class Widget
    module Mutt
      # Includable alias pack: `include Crysterm::Widget::Mutt::DSL` pulls
      # the Mutt widget set into the current namespace under short names —
      # the way `include Crysterm::Widgets` does for the core set — so a
      # Mutt-style app needs no per-class alias lines. Include it *after*
      # `Crysterm::Widgets`, so the pack's spellings (`StatusBar`, …) shadow
      # any same-named core widget.
      module DSL
        alias Sidebar = Mutt::Sidebar
        alias Mailbox = Mutt::Mailbox
        alias MessageIndex = Mutt::MessageIndex
        alias Message = Mutt::Message
        alias StatusBar = Mutt::StatusBar
        alias Compose = Mutt::Compose
        alias Attachment = Mutt::Attachment
      end
    end
  end
end
