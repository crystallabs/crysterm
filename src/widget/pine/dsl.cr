module Crysterm
  class Widget
    module Pine
      # Includable alias pack: `include Crysterm::Widget::Pine::DSL` pulls
      # the Pine widget set into the current namespace under short names —
      # the way `include Crysterm::Widgets` does for the core set — so a
      # Pine-style app needs no per-class alias lines. Include it *after*
      # `Crysterm::Widgets`, so the pack's spellings (`MessageIndex`, …)
      # shadow any same-named core widget.
      module DSL
        alias KeyMenu = Pine::KeyMenu
        alias KeyPrompt = Pine::KeyPrompt
        alias MainMenu = Pine::MainMenu
        alias MessageIndex = Pine::MessageIndex
        alias MessageView = Pine::MessageView
        alias Setup = Pine::Setup
        alias FolderList = Pine::FolderList
        alias AddressBook = Pine::AddressBook
        alias ListSelect = Pine::ListSelect
        alias OptionList = Pine::OptionList
        alias OptionKind = Pine::OptionKind
        alias TextView = Pine::TextView
        alias FileBrowser = Pine::FileBrowser
      end
    end
  end
end
