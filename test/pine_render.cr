require "../src/crysterm"

# Headless render check for the Pine/Alpine widgets: builds each screen, renders
# it synchronously, and prints a plain-text screenshot. Run with:
#   crystal run test/pine_render.cr
include Crysterm
include Widgets

def dump(s, label)
  s._render
  STDOUT.puts "================= #{label} ================="
  STDOUT.puts s.screenshot
  STDOUT.puts
end

s = Screen.new width: 80, height: 22

header = Widget::Pine::HeaderBar.new parent: s, top: 0,
  title_content: "ALPINE 2.26", section_content: "MAIN MENU", info_content: "Folder: INBOX  5 Messages"
status = Widget::Pine::StatusBar.new parent: s, bottom: 2,
  status_content: %([Folder "INBOX" opened with 5 messages])
keys = Widget::Pine::KeyMenu.new parent: s, bottom: 0, entries: [
  Widget::Pine::KeyMenu::Entry.new("?", "Help"),
  Widget::Pine::KeyMenu::Entry.new("C", "Compose"),
  Widget::Pine::KeyMenu::Entry.new("I", "MsgIndex"),
  Widget::Pine::KeyMenu::Entry.new("L", "FolderList"),
  Widget::Pine::KeyMenu::Entry.new("A", "AddrBook"),
  Widget::Pine::KeyMenu::Entry.new("Q", "Quit"),
]

body = {parent: s, top: 1, bottom: 3, left: 0, width: "100%"}

# MAIN MENU is centered in the terminal, the way Alpine presents it.
main_menu = Widget::Pine::MainMenu.new parent: s, top: "center", left: "center", width: 66, height: 13, options: [
  Widget::Pine::MainMenu::Option.new("?", "HELP", "Get help using Alpine"),
  Widget::Pine::MainMenu::Option.new("C", "COMPOSE MESSAGE", "Compose and send a message"),
  Widget::Pine::MainMenu::Option.new("I", "MESSAGE INDEX", "View messages in current folder"),
  Widget::Pine::MainMenu::Option.new("L", "FOLDER LIST", "Select a folder to view"),
  Widget::Pine::MainMenu::Option.new("A", "ADDRESS BOOK", "Update address book"),
  Widget::Pine::MainMenu::Option.new("S", "SETUP", "Configure Alpine options"),
  Widget::Pine::MainMenu::Option.new("Q", "QUIT", "Leave the Alpine program"),
]
main_menu.focus
dump s, "MAIN MENU (centered)"
main_menu.hide

idx = Widget::Pine::MessageIndex.new **body, messages: [
  Widget::Pine::MessageIndex::Message.new("Alpine Team", "Welcome to Alpine!", date: "Jun 18", size: 1234, unread: true, status: "+"),
  Widget::Pine::MessageIndex::Message.new("John Smith", "Re: Project update", date: "Jun 19", size: 5678),
  Widget::Pine::MessageIndex::Message.new("Mailer Daemon", "Delivery Status Notification (Failure)", date: "Jun 20", size: 3405, status: "D"),
]
header.section.content = "MESSAGE INDEX"
idx.focus
dump s, "MESSAGE INDEX"
idx.hide

folders = Widget::Pine::FolderList.new **body, folders: [
  Widget::Pine::FolderList::Folder.new("INBOX", 5),
  Widget::Pine::FolderList::Folder.new("Sent", 12),
  Widget::Pine::FolderList::Folder.new("Drafts", 1),
  Widget::Pine::FolderList::Folder.new("Archive", 0),
]
header.section.content = "FOLDER LIST"
folders.focus
dump s, "FOLDER LIST"
folders.hide

addr = Widget::Pine::AddressBook.new **body, contacts: [
  Widget::Pine::AddressBook::Contact.new("team", "Alpine Team", "alpine@example.com"),
  Widget::Pine::AddressBook::Contact.new("john", "John Smith", "john.smith@example.com"),
  Widget::Pine::AddressBook::Contact.new("jane", "Jane Doe", "jane@example.com"),
]
header.section.content = "ADDRESS BOOK"
addr.focus
dump s, "ADDRESS BOOK"
addr.hide

compose = Widget::Pine::Compose.new **body
compose.fields["to"]?.try &.value = "jane@example.com"
compose.fields["subject"]?.try &.value = "Lunch?"
header.section.content = "COMPOSE MESSAGE"
compose.focus_first
dump s, "COMPOSE MESSAGE"
compose.hide

setup = Widget::Pine::Setup.new **body, options: [
  Widget::Pine::Setup::Option.new("enable-incoming-folders", "Show the incoming-folders collection", enabled: true),
  Widget::Pine::Setup::Option.new("expanded-view-of-folders", "Always expand folder collections"),
  Widget::Pine::Setup::Option.new("enable-cruise-mode", "Skip the MAIN MENU on startup"),
]
header.section.content = "SETUP CONFIGURATION"
setup.focus
dump s, "SETUP CONFIGURATION"

s.destroy
