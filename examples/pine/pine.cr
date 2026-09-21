require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Proof-of-concept Pine/Alpine-style TUI mail client built from the
# `Crysterm::Widget::Pine` widget set. All content is mocked; nothing is read
# from disk or sent over the network. Demonstrates navigating between the
# Alpine screens and reproduces Alpine's keyboard shortcuts:
#
#   MAIN MENU      pick a command (arrows + Enter, or the letter keys)
#   MESSAGE INDEX  browse the (fake) INBOX
#   MESSAGE TEXT   read a message (arrows / PageUp / PageDown to scroll)
#   COMPOSE        edit a message (Tab between fields, ^X send, ^C cancel)
#   SETUP          toggle configuration features (Space / Enter)
#   CONFIG         edit typed settings (text / number / choice)
#   FOLDER LIST    pick a folder
#   ADDRESS BOOK   pick a contact to write to
#   SORT ORDER     pick how the index is sorted (single-select list)
#   FLAG MAINT.    set flags on a message (multi-select checkbox list)
#   ATTACH FILE    browse the filesystem to attach a file
#   HELP           scrollable help text
#
# It also shows the transient Pine chrome: a status-line yes/no prompt
# (`KeyPrompt`, e.g. quit / expunge confirmation) and a percent-done bar
# (`ProgressBar`, shown briefly while a message is "sent").
#
# Global keys mirror Alpine's bottom command bar; ^Q quits from anywhere.
#
# The program is split in two files. `ui.cr` is the reusable part: `PineUI`
# builds the frame, the shared and transient chrome and the full-screen views,
# and offers the helpers that switch between them (show a view, set the key
# bar, ask yes/no, run the progress bar). This file is the client: the mock
# mailbox and option data, the screen flows and the Alpine key bindings. To
# build your own Alpine-style app, keep `ui.cr` and replace this file.
#
# Run with:  crystal examples/pine/pine.cr   (TERM=xterm-256color recommended)
include Tput::Namespace

# The Pine widget pack's alias set (KeyMenu, MainMenu, MessageIndex, …).
include CT::Widget::Pine::DSL

require "./ui"

s = CT::Window.new(
  always_propagated_keys: [Tput::Key::CtrlQ],
  title: "Crysterm — Alpine-style demo",
)

# ----------------------------------------------------------------- mock data

messages = [
  MessageIndex::Message.new("Alpine Team", "Welcome to Alpine!",
    date: "Jun 18", size: 1_234, unread: true, status: "+"),
  MessageIndex::Message.new("John Smith", "Re: Project update",
    date: "Jun 19", size: 5_678),
  MessageIndex::Message.new("Jane Doe", "Lunch on Friday?",
    date: "Jun 19", size: 842, unread: true),
  MessageIndex::Message.new("Crystal Weekly", "Issue #412: Macros deep-dive",
    date: "Jun 21", size: 9_002, status: "*"),
  MessageIndex::Message.new("GitHub", "[crystallabs/crysterm] New release v1.0.0",
    date: "Jun 20", size: 12_910, status: "A"),
  MessageIndex::Message.new("Security Team", "Action required: rotate your keys",
    date: "Jun 22", size: 4_096, unread: true, status: "+"),
  MessageIndex::Message.new("Mailer Daemon", "Delivery Status Notification (Failure)",
    date: "Jun 20", size: 3_405, status: "D"),
  MessageIndex::Message.new("Jane Doe", "Re: Lunch on Friday?",
    date: "Jun 23", size: 1_205, status: "A"),
]

bodies = [
  "Welcome to Alpine, reimagined in Crystal!\n\n" \
  "This is a proof-of-concept interface built entirely from the\n" \
  "Crysterm::Widget::Pine widget set: HeaderBar, StatusBar, KeyMenu,\n" \
  "MainMenu, MessageIndex, MessageView, Compose, Setup, OptionList,\n" \
  "FolderList, AddressBook, ListSelect, KeyPrompt, ProgressBar,\n" \
  "TextView and FileBrowser.\n\nPress '<' to return to the index, or 'R' to reply.\n",
  "Hi,\n\nJust following up on the project update from last week.\n" \
  "Everything is on track and we should hit the milestone on time.\n\nBest,\nJohn\n",
  "Hey!\n\nAre you free for lunch this Friday around noon?\n\nCheers,\nJane\n",
  "This week in Crystal:\n\n" \
  "  * A deep dive into macros and AST nodes\n" \
  "  * Shards worth watching\n  * Performance tips for the compiler\n\n" \
  "Read the full issue online.\n",
  "A new release of crysterm has been published.\n\n" \
  "  Version: v1.0.0\n  Tag:     v1.0.0\n\nSee the changelog for details.\n",
  "Our records show you have not rotated your access keys in 90 days.\n\n" \
  "Please rotate them at your earliest convenience to keep your\n" \
  "account secure.\n\n-- The Security Team\n",
  "This is an automatically generated delivery status notification.\n\n" \
  "Delivery to the following recipient failed permanently:\n\n" \
  "    nonexistent@example.invalid\n",
  "Noon on Friday works great — see you then!\n\nJane\n",
]

# The original arrival order, so the "Arrival" sort can be restored.
arrival = messages.dup

# Pair each message with its body by identity, not position: the index can be
# re-sorted or have messages expunged, so a parallel `bodies[i]` lookup would
# show the wrong message's text after sorting.
body_of = {} of MessageIndex::Message => String
messages.each_with_index { |m, i| body_of[m] = bodies[i]? || "" }

# Per-message flags are the source of truth for the index status column and
# the FLAG MAINTENANCE screen; each maps to a status character shown in the
# index. Seeded from each message's initial status/unread.
FLAG_CHARS = {"Important" => "*", "Deleted" => "D", "Answered" => "A", "Forwarded" => "F", "New" => "N"}
flags_of = {} of MessageIndex::Message => Set(String)
messages.each do |m|
  set = Set(String).new
  FLAG_CHARS.each { |name, ch| set << name if m.status.includes?(ch) }
  set << "New" if m.unread?
  flags_of[m] = set
end

# Recompute a message's visible status column (and unread flag) from its flag
# set, so flags are shown in the index and survive sorting/expunging.
apply_flags = ->(m : MessageIndex::Message) do
  fl = flags_of[m]
  m.status = FLAG_CHARS.compact_map { |name, ch| ch if fl.includes?(name) }.join
  m.unread = fl.includes?("New")
  nil
end
messages.each { |m| apply_flags.call m }

SORT_ORDERS = ["Arrival", "Date", "From", "Subject", "Size"]
FLAG_NAMES  = ["Important", "New", "Answered", "Deleted", "Forwarded"]

HELP_TEXT = <<-HELP
  This is a proof-of-concept Pine/Alpine-style mail client built with
  Crysterm. Everything you see is mocked up to demonstrate the widgets and
  Alpine's keyboard-driven navigation.

  {bold}General keys{/bold}
    Arrow keys     Move the selection / scroll
    Enter          Select / open the highlighted item
    <              Go back to the previous screen
    ?              Show this help (from most screens)
    ^Q             Quit from anywhere

  {bold}Main menu{/bold}
    C  Compose      I  Message Index   L  Folder List
    A  Address Book S  Setup           Q  Quit

  {bold}Message index{/bold}
    Enter / V  Read     N / P  Next / Prev   R  Reply
    D  Delete           U  Undelete          X  Expunge
    $  Sort order       *  Flag maintenance  <  Back

  {bold}Compose{/bold}
    Tab/Enter  Next field   ^X  Send    ^C  Cancel
    ^T  Attach file   ^O  Postpone   ^G  Help

  {bold}Setup{/bold}
    Space/Enter  Toggle feature     C  Config editor

  This help pane is a {bold}Pine::TextView{/bold} — scroll it with the arrow
  keys, PageUp/PageDown, and Home/End. Press '<' to return to the main menu.
  HELP

# The content of the option screens.

menu_options = [
  MainMenu::Option.new("?", "HELP", "Get help using Alpine"),
  MainMenu::Option.new("C", "COMPOSE MESSAGE", "Compose and send a message"),
  MainMenu::Option.new("I", "MESSAGE INDEX", "View messages in current folder"),
  MainMenu::Option.new("L", "FOLDER LIST", "Select a folder to view"),
  MainMenu::Option.new("A", "ADDRESS BOOK", "Update address book"),
  MainMenu::Option.new("S", "SETUP", "Configure Alpine options"),
  MainMenu::Option.new("Q", "QUIT", "Leave the Alpine program"),
]

setup_options = [
  Setup::Option.new("enable-incoming-folders", "Show the incoming-folders collection", enabled: true),
  Setup::Option.new("enable-aggregate-commands", "Operate on several messages at once", enabled: true),
  Setup::Option.new("expanded-view-of-folders", "Always expand folder collections"),
  Setup::Option.new("enable-cruise-mode", "Skip the MAIN MENU on startup"),
  Setup::Option.new("quell-status-messages", "Suppress most status-line messages"),
  Setup::Option.new("enable-dot-files", "Show files beginning with a dot"),
  Setup::Option.new("strip-from-sigdashes", "Strip the '-- ' before signatures"),
]

config_options = [
  OptionList::Option.new("personal-name", OptionKind::Text, "Your full name", value: "Crystal User"),
  OptionList::Option.new("smtp-server", OptionKind::Text, "Outgoing mail server", value: "smtp.example.com"),
  OptionList::Option.new("composer-wrap-column", OptionKind::Number, "Wrap the composer at column", value: "74"),
  OptionList::Option.new("scroll-margin", OptionKind::Number, "Keep N lines visible when scrolling", value: "2"),
  OptionList::Option.new("saved-msg-name-rule", OptionKind::Choice, "Default Fcc rule", value: "last-folder-used",
    allowed: ["default-folder", "last-folder-used", "by-recipient"]),
  OptionList::Option.new("sort-key", OptionKind::Choice, "Default index sort", value: "Arrival", allowed: SORT_ORDERS),
  OptionList::Option.new("color-style", OptionKind::Choice, "Color theme", value: "dark", allowed: ["dark", "light", "none"]),
  OptionList::Option.new("enable-newmail-sound", OptionKind::Toggle, "Beep on new mail", value: "true"),
]

folders = [
  FolderList::Folder.new("INBOX", messages.size),
  FolderList::Folder.new("Sent", 12),
  FolderList::Folder.new("Drafts", 1),
  FolderList::Folder.new("Trash", 3),
  FolderList::Folder.new("Archive", 0),
]

contacts = [
  AddressBook::Contact.new("team", "Alpine Team", "alpine@example.com"),
  AddressBook::Contact.new("john", "John Smith", "john.smith@example.com"),
  AddressBook::Contact.new("jane", "Jane Doe", "jane@example.com"),
  AddressBook::Contact.new("github", "GitHub", "noreply@github.com"),
]

# ------------------------------------------------------------------- the UI

ui = PineUI.new(s,
  menu_options: menu_options,
  messages: messages,
  help_text: HELP_TEXT,
  setup_options: setup_options,
  config_options: config_options,
  folders: folders,
  contacts: contacts,
  sort_orders: SORT_ORDERS,
  flag_names: FLAG_NAMES,
)
# Widen the status column so all of a message's flags show at once (up to 5: *DAFN).
ui.index.status_width = FLAG_CHARS.size + 1

# ------------------------------------------------------------- screen state

current = :main
current_sort = "Arrival"
flag_target : MessageIndex::Message? = nil

# ----------------------------------------------------------- the screen flows

goto_main = -> do
  current = :main
  ui.header.section.content = "MAIN MENU"
  ui.header.info.content = "Folder: INBOX  #{messages.size} Messages"
  ui.show_only ui.main_menu
  ui.banner.show
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("C", "Compose"),
    KeyMenu::Entry.new("I", "MsgIndex"),
    KeyMenu::Entry.new("L", "FolderList"),
    KeyMenu::Entry.new("A", "AddrBook"),
    KeyMenu::Entry.new("Q", "Quit"),
  ]
  ui.show_status %([Folder "INBOX" opened with #{messages.size} messages])
  nil
end

goto_index = -> do
  current = :index
  ui.header.section.content = "MESSAGE INDEX"
  ui.header.info.content = "Folder: INBOX  #{messages.size} Messages  (by #{current_sort})"
  ui.show_only ui.index
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("<", "MainMenu"),
    KeyMenu::Entry.new("V", "ViewMsg"),
    KeyMenu::Entry.new("C", "Compose"),
    KeyMenu::Entry.new("R", "Reply"),
    KeyMenu::Entry.new("D", "Delete"),
    KeyMenu::Entry.new("U", "Undelete"),
    KeyMenu::Entry.new("X", "Expunge"),
    KeyMenu::Entry.new("$", "SortIdx"),
    KeyMenu::Entry.new("*", "Flag"),
    KeyMenu::Entry.new("Q", "Quit"),
  ]
  ui.show_status "[Arrows or click to move, Enter/V/dbl-click to read, C compose, ? help]"
  nil
end

open_message = ->(m : MessageIndex::Message) do
  current = :view
  i = messages.index(m) || 0
  ui.index.current_index = i
  ui.header.section.content = "MESSAGE TEXT"
  ui.header.info.content = "Msg #{i + 1} of #{messages.size}"
  ui.view.set_message(from: m.from, to: "you@example.com", date: m.date, subject: m.subject, body: body_of[m]? || "")
  ui.show_only ui.view
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("<", "Index"),
    KeyMenu::Entry.new("P", "PrevMsg"),
    KeyMenu::Entry.new("N", "NextMsg"),
    KeyMenu::Entry.new("D", "Delete"),
    KeyMenu::Entry.new("R", "Reply"),
  ]
  ui.show_status %([Reading message #{i + 1}: "#{m.subject}"])
  nil
end

# Show the composer. *reset* clears the fields first (new message) or keeps
# them (e.g. returning from the attachment browser). *focus* names the field
# to land on — a header field name (e.g. "to", "attchmnt") or "body".
show_compose = ->(reset : Bool, focus : String) do
  current = :compose
  ui.header.section.content = "COMPOSE MESSAGE"
  ui.header.info.content = ""
  ui.compose.reset if reset
  ui.show_only ui.compose
  if focus == "body"
    ui.compose.body.focus
  else
    ui.compose.focus_field focus
  end
  ui.set_keys [
    KeyMenu::Entry.new("^X", "Send"),
    KeyMenu::Entry.new("^C", "Cancel"),
    KeyMenu::Entry.new("^T", "Attach"),
    KeyMenu::Entry.new("^O", "Postpone"),
    KeyMenu::Entry.new("Tab", "NextField"),
    KeyMenu::Entry.new("^G", "Help"),
  ]
  ui.show_status "[Compose: Tab/Enter or click a field; ^X send, ^T attach, ^C cancel]"
  nil
end

# Open the composer on a new message addressed to *to* with *subject*, landing
# the cursor on *focus* ("to" for a fresh message, "body" for a reply).
goto_compose = ->(to : String, subject : String, focus : String) do
  show_compose.call true, focus
  ui.compose.fields["to"]?.try &.value = to
  ui.compose.fields["subject"]?.try &.value = subject
  nil
end

goto_setup = -> do
  current = :setup
  ui.header.section.content = "SETUP"
  ui.header.info.content = "#{ui.setup.options.count(&.enabled?)} of #{ui.setup.options.size} enabled"
  ui.show_only ui.setup
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("E", "Exit"),
    KeyMenu::Entry.new("Spc", "Toggle"),
    KeyMenu::Entry.new("C", "Config"),
    KeyMenu::Entry.new("<", "MainMenu"),
  ]
  ui.show_status "[Setup: arrows/click to move, Space/Enter/click toggle, C config, E exit]"
  nil
end

goto_config = -> do
  current = :config
  ui.header.section.content = "SETUP CONFIGURATION"
  ui.header.info.content = ""
  ui.show_only ui.config
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("<", "Setup"),
    KeyMenu::Entry.new("Enter", "Change"),
  ]
  ui.show_status "[Config: Enter or click a row toggles/cycles/edits its value, < to go back]"
  nil
end

goto_folders = -> do
  current = :folders
  ui.header.section.content = "FOLDER LIST"
  ui.header.info.content = "Collection <Mail>"
  ui.show_only ui.folders
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("<", "MainMenu"),
    KeyMenu::Entry.new("Enter", "OpenFldr"),
  ]
  ui.show_status "[Select a folder and press Enter — or click it — to open it]"
  nil
end

goto_addrbook = -> do
  current = :addrbook
  ui.header.section.content = "ADDRESS BOOK"
  ui.header.info.content = "#{ui.addrbook.contacts.size} contacts"
  ui.show_only ui.addrbook
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("<", "MainMenu"),
    KeyMenu::Entry.new("Enter", "Compose"),
  ]
  ui.show_status "[Select a contact and press Enter — or click it — to write to them]"
  nil
end

goto_sort = -> do
  current = :sort
  ui.header.section.content = "SELECT SORT ORDER"
  ui.header.info.content = "Currently: #{current_sort}"
  ui.show_only ui.sortpick
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("<", "Index"),
    KeyMenu::Entry.new("Enter", "Select"),
  ]
  ui.show_status "[Choose how to sort the index, then press Enter (or click an order)]"
  nil
end

goto_flag = -> do
  current = :flag
  m = ui.index.selected_message
  flag_target = m
  ui.header.section.content = "FLAG MAINTENANCE"
  ui.header.info.content = m ? %(Msg: "#{m.subject}") : ""
  # Preselect the message's current flags.
  m ? (ui.flagpick.checked = FLAG_NAMES.select { |f| flags_of[m].includes?(f) }) : ui.flagpick.clear_selection
  ui.show_only ui.flagpick
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("<", "ApplyBack"),
    KeyMenu::Entry.new("Spc", "Toggle"),
    KeyMenu::Entry.new("Enter", "Toggle"),
  ]
  ui.show_status "[Space/Enter/click toggles a flag; < applies them and returns]"
  nil
end

goto_attach = -> do
  current = :attach
  ui.header.section.content = "SELECT FILE TO ATTACH"
  ui.header.info.content = ui.filebrowser.cwd
  ui.show_only ui.filebrowser
  ui.filebrowser.refresh
  ui.set_keys [
    KeyMenu::Entry.new("?", "Help"),
    KeyMenu::Entry.new("<", "Compose"),
    KeyMenu::Entry.new("Enter", "Select"),
  ]
  ui.show_status "[Enter or click opens a directory / attaches a file; < to cancel]"
  nil
end

goto_help = -> do
  current = :help
  ui.header.section.content = "HELP TEXT"
  ui.header.info.content = ""
  ui.show_only ui.help
  ui.set_keys [
    KeyMenu::Entry.new("<", "Back"),
    KeyMenu::Entry.new("Up", "ScrollUp"),
    KeyMenu::Entry.new("Dn", "ScrollDn"),
    KeyMenu::Entry.new("PgDn", "PageDn"),
  ]
  ui.show_status "[Help: arrows / PageUp/Down / Home/End or mouse wheel to scroll, < to return]"
  nil
end

# ------------------------------------------------------------- wiring it up

ui.main_menu.options[0].callback { goto_help.call }
ui.main_menu.options[1].callback { goto_compose.call("", "", "to") }
ui.main_menu.options[2].callback { goto_index.call }
ui.main_menu.options[3].callback { goto_folders.call }
ui.main_menu.options[4].callback { goto_addrbook.call }
ui.main_menu.options[5].callback { goto_setup.call }
ui.main_menu.options[6].callback { ui.ask_yes_no("Really quit ALPINE? ") { s.quit } }

messages.each do |m|
  m.callback { open_message.call(m) }
end

ui.folders.folders.each do |f|
  f.callback do
    if f.name == "INBOX"
      goto_index.call
    else
      ui.show_status %([Folder "#{f.name}" is empty or unavailable in this demo])
    end
  end
end

ui.addrbook.contacts.each do |c|
  c.callback { goto_compose.call(c.recipient, "", "to") }
end

ui.setup.options.each do |o|
  o.callback do |on|
    ui.header.info.content = "#{ui.setup.options.count(&.enabled?)} of #{ui.setup.options.size} enabled"
    ui.show_status "[#{o.name} is now #{on ? "ON" : "OFF"}]"
  end
end

ui.config.options.each do |o|
  o.callback do |value|
    ui.show_status "[#{o.name} set to #{value.empty? ? "(empty)" : value}]"
  end
end

# SORT ORDER picker (single-select `ListSelect`): Enter confirms the
# highlighted order, reorders the index, and returns to it.
ui.sortpick.confirm_handler do |sel|
  sel.first?.try do |o|
    current_sort = o
    case o
    when "Arrival" then messages.replace(arrival.select { |m| messages.includes?(m) })
    when "Date"    then messages.sort_by!(&.date)
    when "From"    then messages.sort_by!(&.from.downcase)
    when "Subject" then messages.sort_by!(&.subject.downcase.sub(/^re:\s*/, ""))
    when "Size"    then messages.sort_by!(&.size)
    end
    ui.index.messages = messages
  end
  ui.show_status "[Index sorted by #{current_sort}]"
  goto_index.call
end

# FLAG MAINTENANCE (multi-select `ListSelect`): leaving the screen ("<")
# calls `flagpick.confirm`, which applies checked flags and returns to the index.
ui.flagpick.confirm_handler do |sel|
  flag_target.try do |m|
    flags_of[m] = sel.to_set
    apply_flags.call m
    ui.index.messages = messages
  end
  ui.show_status(sel.empty? ? "[Flags cleared]" : "[Flags set: #{sel.join(", ")}]")
  goto_index.call
end

# ATTACH FILE (FileBrowser): selecting a file fills the composer's Attchmnt
# field and returns; navigating directories updates the info line.
ui.filebrowser.on(CT::Event::FileSelected) do |e|
  ui.compose.fields["attchmnt"]?.try &.value = File.basename(e.path)
  show_compose.call false, "attchmnt"
  ui.show_status "[Attached: #{File.basename(e.path)}]"
end

ui.filebrowser.on(CT::Event::DirectoryChanged) do
  ui.header.info.content = ui.filebrowser.cwd
  ui.show_status "[#{ui.filebrowser.cwd}]"
end

reply_to = ->(m : MessageIndex::Message) do
  addr = "#{m.from} <#{m.from.downcase.gsub(' ', '.')}@example.com>"
  goto_compose.call(addr, "Re: #{m.subject}", "body")
  nil
end

expunge = -> do
  deleted = messages.count { |m| flags_of[m].includes?("Deleted") }
  if deleted.zero?
    ui.show_status "[No deleted messages to expunge]"
  else
    ui.ask_yes_no("Expunge the #{deleted} deleted message#{deleted == 1 ? "" : "s"}? ") do
      messages.reject! { |m| flags_of[m].includes?("Deleted") }
      ui.index.messages = messages
      ui.header.info.content = "Folder: INBOX  #{messages.size} Messages  (by #{current_sort})"
      ui.show_status "[Expunged #{deleted} message#{deleted == 1 ? "" : "s"}]"
    end
  end
  nil
end

# ----------------------------------------------------- Alpine key shortcuts
#
# The screen-level handler sees every keypress before the focused widget, so
# these global commands work even with a list or text field focused. Each
# screen has its own command set, matching the bottom KeyMenu.

s.on(CT::Event::KeyPress) do |e|
  ch = e.char
  key = e.key

  if key == Tput::Key::CtrlQ
    # Graceful app-level quit — see `Window#quit` (vs a bare `exit`).
    s.quit
  end

  # While a yes/no prompt is up it owns the keyboard: its own handler
  # processes Y/N, swallow everything else here, Escape means "no".
  if ui.prompt_active?
    ui.dismiss_prompt if key == Tput::Key::Escape
    next
  end

  # Escape goes "back" one screen, mirroring '<'. Compose keeps its own
  # Escape (cancel), handled below. Mid inline-edit, Escape must cancel the
  # edit (handled by OptionList itself), not exit the Config screen.
  if key == Tput::Key::Escape && current != :compose
    handled = true
    case current
    when :config
      if ui.config.editing?
        handled = false
      else
        goto_setup.call
      end
    when :sort                                      then goto_index.call
    when :flag                                      then ui.flagpick.confirm
    when :attach                                    then show_compose.call false, "attchmnt"
    when :view                                      then goto_index.call
    when :index, :setup, :folders, :addrbook, :help then goto_main.call
    else                                                 handled = false
    end
    next if handled
  end

  case current
  when :main
    case ch
    when 'i', 'I' then goto_index.call
    when 'c', 'C' then goto_compose.call("", "", "to")
    when 's', 'S' then goto_setup.call
    when 'l', 'L' then goto_folders.call
    when 'a', 'A' then goto_addrbook.call
    when 'q', 'Q' then ui.ask_yes_no("Really quit ALPINE? ") { s.quit }
    when '?'      then goto_help.call
    end
  when :index
    case ch
    when '<', 'l', 'L' then goto_main.call
    when 'v', 'V', '>' then ui.index.selected_message.try { |m| open_message.call(m) }
    when 'c', 'C'      then goto_compose.call("", "", "to")
    when 'n', 'N'      then ui.index.down
    when 'p', 'P'      then ui.index.up
    when 'r', 'R'      then ui.index.selected_message.try { |m| reply_to.call(m) }
    when '$'           then goto_sort.call
    when '*'           then goto_flag.call
    when 'x', 'X'      then expunge.call
    when 'd', 'D'
      ui.index.selected_message.try do |m|
        flags_of[m] << "Deleted"
        apply_flags.call m
        ui.index.messages = messages
        ui.show_status "[Message marked for deletion]"
      end
    when 'u', 'U'
      ui.index.selected_message.try do |m|
        flags_of[m].delete "Deleted"
        apply_flags.call m
        ui.index.messages = messages
        ui.show_status "[Message undeleted]"
      end
    when 'q', 'Q' then ui.ask_yes_no("Really quit ALPINE? ") { s.quit }
    when '?'      then goto_help.call
    end
  when :view
    case ch
    when '<', 'i', 'I' then goto_index.call
    when 'n', 'N'
      ni = ui.index.current_index + 1
      messages[ni]?.try { |m| open_message.call(m) } if ni < messages.size
    when 'p', 'P'
      pi = ui.index.current_index - 1
      messages[pi]?.try { |m| open_message.call(m) } if pi >= 0
    when 'r', 'R' then messages[ui.index.current_index]?.try { |m| reply_to.call(m) }
    when 'd', 'D'
      messages[ui.index.current_index]?.try do |m|
        flags_of[m] << "Deleted"
        apply_flags.call m
        ui.index.messages = messages
        ui.show_status "[Message marked for deletion]"
      end
    when '?' then goto_help.call
    end
  when :compose
    case key
    when Tput::Key::CtrlX
      vals = ui.compose.values
      ui.run_progress "Sending message..."
      goto_main.call
      ui.show_status %([Message to "#{vals["to"].empty? ? "(nobody)" : vals["to"]}" sent])
    when Tput::Key::CtrlT
      goto_attach.call
    when Tput::Key::CtrlG
      goto_help.call
    when Tput::Key::CtrlO
      goto_main.call
      ui.show_status "[Message postponed]"
    when Tput::Key::CtrlC, Tput::Key::Escape
      goto_main.call
      ui.show_status "[Compose cancelled]"
    end
  when :setup
    case ch
    when 'e', 'E', '<' then goto_main.call
    when 'c', 'C'      then goto_config.call
    when '?'           then goto_help.call
    end
  when :config
    case ch
    when '<' then goto_setup.call
    when '?' then goto_help.call
    end
  when :folders
    case ch
    when '<' then goto_main.call
    when '?' then goto_help.call
    end
  when :addrbook
    case ch
    when '<' then goto_main.call
    when '?' then goto_help.call
    end
  when :sort
    case ch
    when '<' then goto_index.call
    when '?' then goto_help.call
    end
  when :flag
    case ch
    when '<' then ui.flagpick.confirm
    when '?' then goto_help.call
    end
  when :attach
    case ch
    when '<' then show_compose.call false, "attchmnt"
    when '?' then goto_help.call
    end
  when :help
    case ch
    when '<', 'i', 'I' then goto_main.call
    end
  end
end

goto_main.call
s.exec
