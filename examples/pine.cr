require "../src/crysterm"

# Proof-of-concept Pine/Alpine-style TUI mail client built from the
# `Crysterm::Widget::Pine` widget set. All content is mocked; nothing is read
# from disk or sent over the network. It demonstrates navigating between the
# Alpine screens and reproduces Alpine's keyboard shortcuts:
#
#   MAIN MENU      pick a command (arrows + Enter, or the letter keys)
#   MESSAGE INDEX  browse the (fake) INBOX
#   MESSAGE TEXT   read a message (arrows / PageUp / PageDown to scroll)
#   COMPOSE        edit a message (Tab between fields, ^X send, ^C cancel)
#   SETUP          toggle configuration features (Space / Enter)
#   FOLDER LIST    pick a folder
#   ADDRESS BOOK   pick a contact to write to
#   HELP           scrollable help text
#
# Global keys mirror Alpine's bottom command bar; ^Q quits from anywhere.
#
# Run with:  crystal examples/pine.cr   (TERM=xterm-256color recommended)
module Crysterm
  include Tput::Namespace
  include Widgets

  alias KeyMenu = Widget::Pine::KeyMenu
  alias MainMenu = Widget::Pine::MainMenu
  alias MessageIndex = Widget::Pine::MessageIndex
  alias Setup = Widget::Pine::Setup
  alias FolderList = Widget::Pine::FolderList
  alias AddressBook = Widget::Pine::AddressBook

  s = Screen.new(
    always_propagate: [Tput::Key::CtrlQ],
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
    MessageIndex::Message.new("GitHub", "[crystallabs/crysterm] New release v1.0.0",
      date: "Jun 20", size: 12_910, status: "A"),
    MessageIndex::Message.new("Mailer Daemon", "Delivery Status Notification (Failure)",
      date: "Jun 20", size: 3_405, status: "D"),
  ]

  bodies = [
    "Welcome to Alpine, reimagined in Crystal!\n\n" \
    "This is a proof-of-concept interface built entirely from the\n" \
    "Crysterm::Widget::Pine widget set: HeaderBar, StatusBar, KeyMenu,\n" \
    "MainMenu, MessageIndex, MessageView, Compose, Setup, FolderList\n" \
    "and AddressBook.\n\nPress '<' to return to the index, or 'R' to reply.\n",
    "Hi,\n\nJust following up on the project update from last week.\n" \
    "Everything is on track and we should hit the milestone on time.\n\nBest,\nJohn\n",
    "Hey!\n\nAre you free for lunch this Friday around noon?\n\nCheers,\nJane\n",
    "A new release of crysterm has been published.\n\n" \
    "  Version: v1.0.0\n  Tag:     v1.0.0\n\nSee the changelog for details.\n",
    "This is an automatically generated delivery status notification.\n\n" \
    "Delivery to the following recipient failed permanently:\n\n" \
    "    nonexistent@example.invalid\n",
  ]

  HELP_TEXT = <<-HELP
    This is a proof-of-concept Pine/Alpine-style mail client built with
    Crysterm. Everything you see is mocked up to demonstrate the widgets and
    Alpine's keyboard-driven navigation.

    General keys
      Arrow keys     Move the selection / scroll
      Enter          Select / open the highlighted item
      <              Go back to the previous screen
      ?              Show this help (from most screens)
      ^Q             Quit from anywhere

    Main menu
      C  Compose      I  Message Index   L  Folder List
      A  Address Book S  Setup           Q  Quit

    Message index
      Enter / V  Read     N / P  Next / Prev   R  Reply
      D  Delete          U  Undelete           <  Back

    Compose
      Tab  Next field    ^X  Send             ^C  Cancel

    Press '<' to return to the main menu.
    HELP

  # ------------------------------------------------------------- shared chrome

  header = Widget::Pine::HeaderBar.new(
    parent: s, top: 0,
    title_content: "ALPINE 2.26",
    section_content: "MAIN MENU",
    info_content: "Folder: INBOX",
  )

  status = Widget::Pine::StatusBar.new(parent: s, bottom: 2, status_content: "")
  key_menu = KeyMenu.new(parent: s, bottom: 0)

  show_status = ->(text : String) do
    status.status.content = text
    s.render
  end

  set_keys = ->(entries : Array(KeyMenu::Entry)) do
    key_menu.set_entries entries
    nil
  end

  # ----------------------------------------------------------------- the views
  #
  # The list/text views fill the body rectangle; the sparse MAIN MENU is
  # centered in the terminal, the way Alpine presents it. Only one is shown at
  # a time.

  body_opts = {parent: s, top: 1, bottom: 3, left: 0, width: "100%"}

  main_menu = MainMenu.new(
    parent: s, top: "center", left: "center", width: 66, height: 13,
    options: [
      MainMenu::Option.new("?", "HELP", "Get help using Alpine"),
      MainMenu::Option.new("C", "COMPOSE MESSAGE", "Compose and send a message"),
      MainMenu::Option.new("I", "MESSAGE INDEX", "View messages in current folder"),
      MainMenu::Option.new("L", "FOLDER LIST", "Select a folder to view"),
      MainMenu::Option.new("A", "ADDRESS BOOK", "Update address book"),
      MainMenu::Option.new("S", "SETUP", "Configure Alpine options"),
      MainMenu::Option.new("Q", "QUIT", "Leave the Alpine program"),
    ])

  index = MessageIndex.new(**body_opts, messages: messages, visible: false)
  view = Widget::Pine::MessageView.new(**body_opts, visible: false)
  compose = Widget::Pine::Compose.new(**body_opts, visible: false)
  help = Widget::Pine::MessageView.new(**body_opts, visible: false, body: HELP_TEXT)

  setup = Setup.new(**body_opts, visible: false, options: [
    Setup::Option.new("enable-incoming-folders", "Show the incoming-folders collection", enabled: true),
    Setup::Option.new("enable-aggregate-commands", "Operate on several messages at once", enabled: true),
    Setup::Option.new("expanded-view-of-folders", "Always expand folder collections"),
    Setup::Option.new("enable-cruise-mode", "Skip the MAIN MENU on startup"),
    Setup::Option.new("quell-status-messages", "Suppress most status-line messages"),
    Setup::Option.new("enable-dot-files", "Show files beginning with a dot"),
    Setup::Option.new("strip-from-sigdashes", "Strip the '-- ' before signatures"),
  ])

  folders = FolderList.new(**body_opts, visible: false, folders: [
    FolderList::Folder.new("INBOX", 5),
    FolderList::Folder.new("Sent", 12),
    FolderList::Folder.new("Drafts", 1),
    FolderList::Folder.new("Trash", 3),
    FolderList::Folder.new("Archive", 0),
  ])

  addrbook = AddressBook.new(**body_opts, visible: false, contacts: [
    AddressBook::Contact.new("team", "Alpine Team", "alpine@example.com"),
    AddressBook::Contact.new("john", "John Smith", "john.smith@example.com"),
    AddressBook::Contact.new("jane", "Jane Doe", "jane@example.com"),
    AddressBook::Contact.new("github", "GitHub", "noreply@github.com"),
  ])

  all_views = {main_menu, index, view, compose, help, setup, folders, addrbook}

  # ---------------------------------------------------- screen state & helpers

  current = :main

  show_only = ->(w : Widget) do
    all_views.each { |v| v == w ? v.show : v.hide }
    w.focus
    nil
  end

  goto_main = -> do
    current = :main
    header.section.content = "MAIN MENU"
    header.info.content = "Folder: INBOX  #{messages.size} Messages"
    show_only.call main_menu
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("C", "Compose"),
      KeyMenu::Entry.new("I", "MsgIndex"),
      KeyMenu::Entry.new("L", "FolderList"),
      KeyMenu::Entry.new("A", "AddrBook"),
      KeyMenu::Entry.new("Q", "Quit"),
    ]
    show_status.call %([Folder "INBOX" opened with #{messages.size} messages])
    nil
  end

  goto_index = -> do
    current = :index
    header.section.content = "MESSAGE INDEX"
    header.info.content = "Folder: INBOX  #{messages.size} Messages"
    show_only.call index
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("<", "MainMenu"),
      KeyMenu::Entry.new("V", "ViewMsg"),
      KeyMenu::Entry.new("C", "Compose"),
      KeyMenu::Entry.new("D", "Delete"),
      KeyMenu::Entry.new("R", "Reply"),
    ]
    show_status.call "[Arrows to move, Enter/V to read, C compose, Q quit]"
    nil
  end

  open_message = ->(i : Int32) do
    current = :view
    m = messages[i]
    index.selekt i
    header.section.content = "MESSAGE TEXT"
    header.info.content = "Msg #{i + 1} of #{messages.size}"
    view.set_message(from: m.from, to: "you@example.com", date: m.date, subject: m.subject, body: bodies[i])
    show_only.call view
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("<", "Index"),
      KeyMenu::Entry.new("P", "PrevMsg"),
      KeyMenu::Entry.new("N", "NextMsg"),
      KeyMenu::Entry.new("D", "Delete"),
      KeyMenu::Entry.new("R", "Reply"),
    ]
    show_status.call %([Reading message #{i + 1}: "#{m.subject}"])
    nil
  end

  goto_compose = ->(to : String, subject : String) do
    current = :compose
    header.section.content = "COMPOSE MESSAGE"
    header.info.content = ""
    compose.reset
    compose.fields["to"]?.try &.value = to
    compose.fields["subject"]?.try &.value = subject
    show_only.call compose
    compose.focus_first
    set_keys.call [
      KeyMenu::Entry.new("^X", "Send"),
      KeyMenu::Entry.new("^C", "Cancel"),
      KeyMenu::Entry.new("Tab", "NextField"),
      KeyMenu::Entry.new("?", "Help"),
    ]
    show_status.call "[Compose: Tab between fields, ^X to send, ^C to cancel]"
    nil
  end

  goto_setup = -> do
    current = :setup
    header.section.content = "SETUP CONFIGURATION"
    header.info.content = "#{setup.options.count(&.enabled?)} of #{setup.options.size} enabled"
    show_only.call setup
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("E", "Exit"),
      KeyMenu::Entry.new("Spc", "Toggle"),
      KeyMenu::Entry.new("<", "MainMenu"),
    ]
    show_status.call "[Setup: arrows to move, Space/Enter to toggle, E to exit]"
    nil
  end

  goto_folders = -> do
    current = :folders
    header.section.content = "FOLDER LIST"
    header.info.content = "Collection <Mail>"
    show_only.call folders
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("<", "MainMenu"),
      KeyMenu::Entry.new("Enter", "OpenFldr"),
    ]
    show_status.call "[Select a folder and press Enter to open it]"
    nil
  end

  goto_addrbook = -> do
    current = :addrbook
    header.section.content = "ADDRESS BOOK"
    header.info.content = "#{addrbook.contacts.size} contacts"
    show_only.call addrbook
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("<", "MainMenu"),
      KeyMenu::Entry.new("Enter", "Compose"),
    ]
    show_status.call "[Select a contact and press Enter to write to them]"
    nil
  end

  goto_help = -> do
    current = :help
    header.section.content = "HELP TEXT"
    header.info.content = ""
    show_only.call help
    set_keys.call [
      KeyMenu::Entry.new("<", "MainMenu"),
      KeyMenu::Entry.new("Up", "ScrollUp"),
      KeyMenu::Entry.new("Dn", "ScrollDn"),
    ]
    show_status.call "[Help: arrows / PageUp / PageDown to scroll, < to return]"
    nil
  end

  # ------------------------------------------------------------- wiring it up

  main_menu.options[0].callback = -> { goto_help.call; nil }
  main_menu.options[1].callback = -> { goto_compose.call("", ""); nil }
  main_menu.options[2].callback = -> { goto_index.call; nil }
  main_menu.options[3].callback = -> { goto_folders.call; nil }
  main_menu.options[4].callback = -> { goto_addrbook.call; nil }
  main_menu.options[5].callback = -> { goto_setup.call; nil }
  main_menu.options[6].callback = -> { s.destroy; exit }

  messages.each_with_index do |m, i|
    m.callback = -> { open_message.call(i); nil }
  end

  folders.folders.each do |f|
    f.callback = -> do
      if f.name == "INBOX"
        goto_index.call
      else
        show_status.call %([Folder "#{f.name}" is empty or unavailable in this demo])
      end
      nil
    end
  end

  addrbook.contacts.each do |c|
    c.callback = -> { goto_compose.call(c.recipient, ""); nil }
  end

  setup.options.each do |o|
    o.callback = ->(on : Bool) do
      header.info.content = "#{setup.options.count(&.enabled?)} of #{setup.options.size} enabled"
      show_status.call "[#{o.name} is now #{on ? "ON" : "OFF"}]"
      nil
    end
  end

  reply_to = ->(m : MessageIndex::Message) do
    addr = "#{m.from} <#{m.from.downcase.gsub(' ', '.')}@example.com>"
    goto_compose.call(addr, "Re: #{m.subject}")
    nil
  end

  # ----------------------------------------------------- Alpine key shortcuts
  #
  # The screen-level handler sees every keypress *before* the focused widget,
  # so these global commands work even while a list or text field has focus.
  # Each screen has its own command set, matching the bottom KeyMenu.

  s.on(Event::KeyPress) do |e|
    ch = e.char
    key = e.key

    if key == Tput::Key::CtrlQ
      s.destroy
      exit
    end

    case current
    when :main
      case ch
      when 'i', 'I' then goto_index.call
      when 'c', 'C' then goto_compose.call("", "")
      when 's', 'S' then goto_setup.call
      when 'l', 'L' then goto_folders.call
      when 'a', 'A' then goto_addrbook.call
      when 'q', 'Q' then (s.destroy; exit)
      when '?'      then goto_help.call
      end
    when :index
      case ch
      when '<', 'l', 'L' then goto_main.call
      when 'v', 'V', '>' then open_message.call(index.selected)
      when 'c', 'C'      then goto_compose.call("", "")
      when 'n', 'N'      then (index.down; s.render)
      when 'p', 'P'      then (index.up; s.render)
      when 'r', 'R'      then index.selected_message.try { |m| reply_to.call(m) }
      when 'd', 'D'
        index.selected_message.try do |m|
          m.status = "D"
          index.set_messages messages
          show_status.call "[Message marked for deletion]"
        end
      when 'u', 'U'
        index.selected_message.try do |m|
          m.status = ""
          index.set_messages messages
          show_status.call "[Message undeleted]"
        end
      when '?' then goto_help.call
      end
    when :view
      case ch
      when '<', 'i', 'I' then goto_index.call
      when 'n', 'N'      then open_message.call(Math.min(index.selected + 1, messages.size - 1))
      when 'p', 'P'      then open_message.call(Math.max(index.selected - 1, 0))
      when 'r', 'R'      then messages[index.selected]?.try { |m| reply_to.call(m) }
      when 'd', 'D'
        messages[index.selected]?.try do |m|
          m.status = "D"
          show_status.call "[Message marked for deletion]"
        end
      when '?' then goto_help.call
      end
    when :compose
      case key
      when Tput::Key::CtrlX
        vals = compose.values
        goto_main.call
        show_status.call %([Message to "#{vals["to"].empty? ? "(nobody)" : vals["to"]}" sent])
      when Tput::Key::CtrlC, Tput::Key::Escape
        goto_main.call
        show_status.call "[Compose cancelled]"
      end
    when :setup
      case ch
      when 'e', 'E', '<' then goto_main.call
      when '?'           then goto_help.call
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
    when :help
      case ch
      when '<', 'i', 'I' then goto_main.call
      end
    end
  end

  s.render
  goto_main.call
  s.exec
end
