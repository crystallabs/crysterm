# Example: Crysterm::Widget::Pine::FolderList
#
# Minimal, self-contained example of a single FolderList.
# Run it:     crystal run examples/widget/pine/folder_list/folder_list.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "FolderList" do |screen|
  screen.stylesheet = "Pine::FolderList { border: solid; color: #c0caf5; }"
  fl = Crysterm::Widget::Pine::FolderList.new parent: screen, top: "center", left: "center", width: 34, height: 12, label: " Folders "
  fl.folders = ([
    Crysterm::Widget::Pine::FolderList::Folder.new("INBOX", 12), Crysterm::Widget::Pine::FolderList::Folder.new("Sent", 48),
    Crysterm::Widget::Pine::FolderList::Folder.new("Drafts", 2), Crysterm::Widget::Pine::FolderList::Folder.new("Trash", 7),
  ])
  fl.focus
end
