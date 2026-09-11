# Example: Crysterm::Widget::Pine::FolderList
#
# Minimal, self-contained example of a single FolderList.
# Run it:     crystal run tests/widget/pine/folder_list/folder_list.cr
require "../../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "FolderList" do |window|
  window.stylesheet = "FolderList { border: solid; color: #c0caf5; }"
  fl = CW::PineFolderList.new parent: window, top: "center", left: "center", width: 34, height: 12, label: " Folders "
  fl.folders = ([
    CW::PineFolderList::Folder.new("INBOX", 12), CW::PineFolderList::Folder.new("Sent", 48),
    CW::PineFolderList::Folder.new("Drafts", 2), CW::PineFolderList::Folder.new("Trash", 7),
  ])
  fl.focus
end
