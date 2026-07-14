require "../../src/crysterm"

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
# The chrome is arranged by *layout* engines, not by fixed top/left/width/height:
# one `Border` frame docks the header on top and a `VBox` footer (status line +
# the two-row command bar) at the bottom, and hands what is left — the body
# rectangle — to every full-screen view. Only the two things that deliberately
# *float* over the body, the MAIN MENU panel and the demo banner, carry
# coordinates.
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
  alias KeyPrompt = Widget::Pine::KeyPrompt
  alias ListSelect = Widget::Pine::ListSelect
  alias OptionList = Widget::Pine::OptionList
  alias OptionKind = Widget::Pine::OptionKind
  alias TextView = Widget::Pine::TextView
  alias FileBrowser = Widget::Pine::FileBrowser

  s = Window.new(
    always_propagate: [Tput::Key::CtrlQ],
    title: "Crysterm — Alpine-style demo",
  )

  # ------------------------------------------------------------------ the frame
  #
  # A single `Border` layout carves the terminal into Alpine's regions: the
  # header on top, a three-row footer at the bottom, and the body — every
  # full-screen view — in the center. `Window` is not a `Widget`, so the frame is
  # a full-screen `Box` on the window that everything else hangs off.
  #
  # It doubles as the backdrop. Created first, it sits behind every other widget,
  # and it paints the cells its regions leave over (e.g. around the centered MAIN
  # MENU). Without it those cells are left to the window's erase path; on a
  # transparent terminal profile they render slightly differently, making the
  # menu look like a distinct rectangle rather than part of the screen.
  frame = Widget::Box.new parent: s, width: "100%", height: "100%",
    layout: Layout::Border.new

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

  # ------------------------------------------------------------- shared chrome

  header = Widget::Pine::HeaderBar.new(
    parent: frame,
    layout_hint: :top,
    title_content: "ALPINE 2.26",
    section_content: "MAIN MENU",
    info_content: "Folder: INBOX",
  )

  # The footer is the one edge where several bars stack, so the `Border`'s bottom
  # region is itself a `VBox`: the status line above the two-row command bar.
  # Only the footer declares a height (the extent it takes off the bottom edge);
  # everything inside it, and the body above it, follows from that.
  footer = Widget::Box.new parent: frame, height: 3, layout: Layout::VBox.new,
    layout_hint: :bottom

  status = Widget::Pine::StatusBar.new(parent: footer, status_content: "")

  # ---------------------------------------------------------- transient chrome
  #
  # A yes/no prompt and a percent-done bar, which take over the status line while
  # active — just as Alpine asks and reports on its message line. They are
  # *siblings* of the status line in the footer rather than boxes floating over
  # it, so the row belongs to whichever of the three is standing: a hidden child
  # releases its slot back to the `VBox`, so showing one and hiding the other two
  # hands the row to the winner. Declared here, ahead of the command bar, because
  # a `VBox` stacks children in the order they were added.

  confirm = KeyPrompt.new(parent: footer, width: "100%", height: 1, visible: false)
  progress = Widget::Pine::ProgressBar.new(parent: footer, width: "100%", height: 1, visible: false, value: 0)

  key_menu = KeyMenu.new(parent: footer)

  # Hand the shared status row to exactly one of its three occupants.
  status_line = ->(w : Widget) do
    {status, confirm, progress}.each { |x| x == w ? x.show : x.hide }
    nil
  end

  # A yellow "this is only a demo" banner, shown on MAIN MENU only. It is not a
  # region: it floats over the body's third row, the way the MAIN MENU itself
  # floats over the body. Docking it under the header would push the body down a
  # row on every *other* screen too, where it is never shown — so it keeps its
  # coordinate, on the window's default `Layout::Manual`.
  banner = Widget::Box.new(
    parent: s, top: 3, left: 0, width: "100%", height: 1,
    align: :hcenter, parse_tags: true, visible: false,
    content: "{#ffff00-fg}** VISUAL DEMO - ALL CONTENT IS IN MEMORY - THERE IS NO DISK OR EMAIL ACCESS **{/#ffff00-fg}",
  )

  show_status = ->(text : String) do
    status.status.content = text
    nil
  end

  set_keys = ->(entries : Array(KeyMenu::Entry)) do
    key_menu.set_entries entries
    nil
  end

  # Make the bottom command bar clickable: a click on a hint emits the hint's
  # key, turned into the matching keypress so it flows through the same
  # handlers as the physical key.
  key_menu.on(Event::Action) do |e|
    kp = case k = e.value.to_s
         when "Spc"   then Event::KeyPress.new(' ', nil)
         when "Enter" then Event::KeyPress.new('\r', Tput::Key::Enter)
         when "Tab"   then Event::KeyPress.new('\t', Tput::Key::Tab)
         when "Up"    then Event::KeyPress.new('\0', Tput::Key::Up)
         when "Dn"    then Event::KeyPress.new('\0', Tput::Key::Down)
         when "PgDn"  then Event::KeyPress.new('\0', Tput::Key::PageDown)
         when "^X"    then Event::KeyPress.new('\0', Tput::Key::CtrlX)
         when "^C"    then Event::KeyPress.new('\0', Tput::Key::CtrlC)
         when "^T"    then Event::KeyPress.new('\0', Tput::Key::CtrlT)
         when "^O"    then Event::KeyPress.new('\0', Tput::Key::CtrlO)
         when "^G"    then Event::KeyPress.new('\0', Tput::Key::CtrlG)
         else
           k.size == 1 ? Event::KeyPress.new(k[0], nil) : nil
         end
    kp.try { |k2| s.emit k2 }
  end

  # ----------------------------------------------------------------- the views
  #
  # Every list/text view is a `Border` *center* child. The five-region carve
  # leaves exactly one rectangle — whatever the header and footer did not take —
  # and the engine hands it to each of them; `show_only` (below) decides which
  # one paints, since only one screen is ever up. That is their entire geometry:
  # not one names a row, a column or a size, and none has to reserve room for the
  # chrome around it.

  body_opts = {parent: frame, layout_hint: :center}

  # MAIN MENU is the deliberate exception. Alpine centers it in the *terminal*,
  # floating over the body rather than filling it — and "centered on something
  # other than my own slot" is not something a layout region can say (centering
  # it in the body region would sit it a row off). So, like a modal panel, it
  # stays a free-floating child of the window on the default `Layout::Manual`.
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
  # Widen the status column so all of a message's flags show at once (up to 5: *DAFN).
  index.status_width = FLAG_CHARS.size + 1
  index.set_messages messages
  view = Widget::Pine::MessageView.new(**body_opts, visible: false)
  compose = Widget::Pine::Compose.new(**body_opts, visible: false)
  help = TextView.new(**body_opts, visible: false, content: HELP_TEXT)

  setup = Setup.new(**body_opts, visible: false, options: [
    Setup::Option.new("enable-incoming-folders", "Show the incoming-folders collection", enabled: true),
    Setup::Option.new("enable-aggregate-commands", "Operate on several messages at once", enabled: true),
    Setup::Option.new("expanded-view-of-folders", "Always expand folder collections"),
    Setup::Option.new("enable-cruise-mode", "Skip the MAIN MENU on startup"),
    Setup::Option.new("quell-status-messages", "Suppress most status-line messages"),
    Setup::Option.new("enable-dot-files", "Show files beginning with a dot"),
    Setup::Option.new("strip-from-sigdashes", "Strip the '-- ' before signatures"),
  ])

  config = OptionList.new(**body_opts, visible: false, options: [
    OptionList::Option.new("personal-name", OptionKind::Text, "Your full name", value: "Crystal User"),
    OptionList::Option.new("smtp-server", OptionKind::Text, "Outgoing mail server", value: "smtp.example.com"),
    OptionList::Option.new("composer-wrap-column", OptionKind::Number, "Wrap the composer at column", value: "74"),
    OptionList::Option.new("scroll-margin", OptionKind::Number, "Keep N lines visible when scrolling", value: "2"),
    OptionList::Option.new("saved-msg-name-rule", OptionKind::Choice, "Default Fcc rule", value: "last-folder-used",
      allowed: ["default-folder", "last-folder-used", "by-recipient"]),
    OptionList::Option.new("sort-key", OptionKind::Choice, "Default index sort", value: "Arrival", allowed: SORT_ORDERS),
    OptionList::Option.new("color-style", OptionKind::Choice, "Color theme", value: "dark", allowed: ["dark", "light", "none"]),
    OptionList::Option.new("enable-newmail-sound", OptionKind::Toggle, "Beep on new mail", value: "true"),
  ])

  folders = FolderList.new(**body_opts, visible: false, folders: [
    FolderList::Folder.new("INBOX", messages.size),
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

  sortpick = ListSelect(String).new(**body_opts, visible: false,
    items: SORT_ORDERS, label: ->(o : String) { o }, multi: false)

  flagpick = ListSelect(String).new(**body_opts, visible: false,
    items: FLAG_NAMES, label: ->(f : String) { f }, multi: true)

  filebrowser = FileBrowser.new(**body_opts, visible: false, cwd: Dir.current)

  all_views = {main_menu, index, view, compose, help, setup, config,
               folders, addrbook, sortpick, flagpick, filebrowser}

  # ---------------------------------------------------- screen state & helpers

  current = :main
  active_view : Widget = main_menu
  current_sort = "Arrival"
  prompt_active = false
  flag_target = nil.as(MessageIndex::Message?)

  show_only = ->(w : Widget) do
    status_line.call status
    banner.hide
    all_views.each { |v| v == w ? v.show : v.hide }
    active_view = w
    w.focus
    nil
  end

  # Refocus whatever full-screen view is current (after a transient prompt is dismissed).
  refocus = -> do
    active_view.focus
    nil
  end

  # Dismiss the status-line yes/no prompt and hand focus back to the view.
  dismiss_prompt = -> do
    prompt_active = false
    status_line.call status
    refocus.call
    nil
  end

  # Pop up a Pine-style yes/no prompt on the status line; *on_yes* runs if the
  # user presses Y. N or Escape just dismisses it.
  ask_yes_no = ->(question : String, on_yes : Proc(Nil)) do
    confirm.set_question question
    confirm.set_choices [
      KeyPrompt::Choice.new("Y", "Yes", -> { dismiss_prompt.call; on_yes.call; nil }),
      KeyPrompt::Choice.new("N", "No", -> { dismiss_prompt.call; nil }),
    ]
    status_line.call confirm
    confirm.focus
    prompt_active = true
    nil
  end

  # Show the percent-done bar and animate it to 100% (mocking a blocking task).
  run_progress = ->(label : String) do
    header.info.content = label
    progress.value = 0
    status_line.call progress
    # Synchronous renders: this mocks a blocking task, stepping the bar from
    # its own loop. The scheduled (coalescing) render would collapse every step
    # into a single frame, so each step paints itself.
    s._render
    0.step(to: 100, by: 10) do |p|
      progress.value = p
      s._render
      sleep 35.milliseconds
    end
    status_line.call status
    nil
  end

  # ----------------------------------------------------------- the screen flows

  goto_main = -> do
    current = :main
    header.section.content = "MAIN MENU"
    header.info.content = "Folder: INBOX  #{messages.size} Messages"
    show_only.call main_menu
    banner.show
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
    header.info.content = "Folder: INBOX  #{messages.size} Messages  (by #{current_sort})"
    show_only.call index
    set_keys.call [
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
    show_status.call "[Arrows or click to move, Enter/V/dbl-click to read, C compose, ? help]"
    nil
  end

  open_message = ->(m : MessageIndex::Message) do
    current = :view
    i = messages.index(m) || 0
    index.current_index = i
    header.section.content = "MESSAGE TEXT"
    header.info.content = "Msg #{i + 1} of #{messages.size}"
    view.set_message(from: m.from, to: "you@example.com", date: m.date, subject: m.subject, body: body_of[m]? || "")
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

  # Show the composer. *reset* clears the fields first (new message) or keeps
  # them (e.g. returning from the attachment browser). *focus* names the field
  # to land on — a header field name (e.g. "to", "attchmnt") or "body".
  show_compose = ->(reset : Bool, focus : String) do
    current = :compose
    header.section.content = "COMPOSE MESSAGE"
    header.info.content = ""
    compose.reset if reset
    show_only.call compose
    if focus == "body"
      compose.body.focus
    else
      compose.focus_field focus
    end
    set_keys.call [
      KeyMenu::Entry.new("^X", "Send"),
      KeyMenu::Entry.new("^C", "Cancel"),
      KeyMenu::Entry.new("^T", "Attach"),
      KeyMenu::Entry.new("^O", "Postpone"),
      KeyMenu::Entry.new("Tab", "NextField"),
      KeyMenu::Entry.new("^G", "Help"),
    ]
    show_status.call "[Compose: Tab/Enter or click a field; ^X send, ^T attach, ^C cancel]"
    nil
  end

  # Open the composer on a new message addressed to *to* with *subject*, landing
  # the cursor on *focus* ("to" for a fresh message, "body" for a reply).
  goto_compose = ->(to : String, subject : String, focus : String) do
    show_compose.call true, focus
    compose.fields["to"]?.try &.value = to
    compose.fields["subject"]?.try &.value = subject
    nil
  end

  goto_setup = -> do
    current = :setup
    header.section.content = "SETUP"
    header.info.content = "#{setup.options.count(&.enabled?)} of #{setup.options.size} enabled"
    show_only.call setup
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("E", "Exit"),
      KeyMenu::Entry.new("Spc", "Toggle"),
      KeyMenu::Entry.new("C", "Config"),
      KeyMenu::Entry.new("<", "MainMenu"),
    ]
    show_status.call "[Setup: arrows/click to move, Space/Enter/click toggle, C config, E exit]"
    nil
  end

  goto_config = -> do
    current = :config
    header.section.content = "SETUP CONFIGURATION"
    header.info.content = ""
    show_only.call config
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("<", "Setup"),
      KeyMenu::Entry.new("Enter", "Change"),
    ]
    show_status.call "[Config: Enter or click a row toggles/cycles/edits its value, < to go back]"
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
    show_status.call "[Select a folder and press Enter — or click it — to open it]"
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
    show_status.call "[Select a contact and press Enter — or click it — to write to them]"
    nil
  end

  goto_sort = -> do
    current = :sort
    header.section.content = "SELECT SORT ORDER"
    header.info.content = "Currently: #{current_sort}"
    show_only.call sortpick
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("<", "Index"),
      KeyMenu::Entry.new("Enter", "Select"),
    ]
    show_status.call "[Choose how to sort the index, then press Enter (or click an order)]"
    nil
  end

  goto_flag = -> do
    current = :flag
    m = index.selected_message
    flag_target = m
    header.section.content = "FLAG MAINTENANCE"
    header.info.content = m ? %(Msg: "#{m.subject}") : ""
    # Preselect the message's current flags.
    m ? flagpick.set_checked(FLAG_NAMES.select { |f| flags_of[m].includes?(f) }) : flagpick.clear_selection
    show_only.call flagpick
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("<", "ApplyBack"),
      KeyMenu::Entry.new("Spc", "Toggle"),
      KeyMenu::Entry.new("Enter", "Toggle"),
    ]
    show_status.call "[Space/Enter/click toggles a flag; < applies them and returns]"
    nil
  end

  goto_attach = -> do
    current = :attach
    header.section.content = "SELECT FILE TO ATTACH"
    header.info.content = filebrowser.cwd
    show_only.call filebrowser
    filebrowser.refresh
    set_keys.call [
      KeyMenu::Entry.new("?", "Help"),
      KeyMenu::Entry.new("<", "Compose"),
      KeyMenu::Entry.new("Enter", "Select"),
    ]
    show_status.call "[Enter or click opens a directory / attaches a file; < to cancel]"
    nil
  end

  goto_help = -> do
    current = :help
    header.section.content = "HELP TEXT"
    header.info.content = ""
    show_only.call help
    set_keys.call [
      KeyMenu::Entry.new("<", "Back"),
      KeyMenu::Entry.new("Up", "ScrollUp"),
      KeyMenu::Entry.new("Dn", "ScrollDn"),
      KeyMenu::Entry.new("PgDn", "PageDn"),
    ]
    show_status.call "[Help: arrows / PageUp/Down / Home/End or mouse wheel to scroll, < to return]"
    nil
  end

  # ------------------------------------------------------------- wiring it up

  main_menu.options[0].callback = -> { goto_help.call; nil }
  main_menu.options[1].callback = -> { goto_compose.call("", "", "to"); nil }
  main_menu.options[2].callback = -> { goto_index.call; nil }
  main_menu.options[3].callback = -> { goto_folders.call; nil }
  main_menu.options[4].callback = -> { goto_addrbook.call; nil }
  main_menu.options[5].callback = -> { goto_setup.call; nil }
  main_menu.options[6].callback = -> { ask_yes_no.call("Really quit ALPINE? ", -> { s.destroy; exit }); nil }

  messages.each do |m|
    m.callback = -> { open_message.call(m); nil }
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
    c.callback = -> { goto_compose.call(c.recipient, "", "to"); nil }
  end

  setup.options.each do |o|
    o.callback = ->(on : Bool) do
      header.info.content = "#{setup.options.count(&.enabled?)} of #{setup.options.size} enabled"
      show_status.call "[#{o.name} is now #{on ? "ON" : "OFF"}]"
      nil
    end
  end

  config.options.each do |o|
    o.callback = ->(value : String) do
      show_status.call "[#{o.name} set to #{value.empty? ? "(empty)" : value}]"
      nil
    end
  end

  # SORT ORDER picker (single-select `ListSelect`): Enter confirms the
  # highlighted order, reorders the index, and returns to it.
  sortpick.on_confirm = ->(sel : Array(String)) do
    sel.first?.try do |o|
      current_sort = o
      case o
      when "Arrival" then messages.replace(arrival.select { |m| messages.includes?(m) })
      when "Date"    then messages.sort_by!(&.date)
      when "From"    then messages.sort_by!(&.from.downcase)
      when "Subject" then messages.sort_by! { |m| m.subject.downcase.sub(/^re:\s*/, "") }
      when "Size"    then messages.sort_by!(&.size)
      end
      index.set_messages messages
    end
    show_status.call "[Index sorted by #{current_sort}]"
    goto_index.call
    nil
  end

  # FLAG MAINTENANCE (multi-select `ListSelect`): leaving the screen ("<")
  # calls `flagpick.confirm`, which applies checked flags and returns to the index.
  flagpick.on_confirm = ->(sel : Array(String)) do
    flag_target.try do |m|
      flags_of[m] = sel.to_set
      apply_flags.call m
      index.set_messages messages
    end
    show_status.call(sel.empty? ? "[Flags cleared]" : "[Flags set: #{sel.join(", ")}]")
    goto_index.call
    nil
  end

  # ATTACH FILE (FileBrowser): selecting a file fills the composer's Attchmnt
  # field and returns; navigating directories updates the info line.
  filebrowser.on(Event::OpenFile) do |e|
    compose.fields["attchmnt"]?.try &.value = File.basename(e.path)
    show_compose.call false, "attchmnt"
    show_status.call "[Attached: #{File.basename(e.path)}]"
  end

  filebrowser.on(Event::ChangeDir) do |e|
    header.info.content = filebrowser.cwd
    show_status.call "[#{filebrowser.cwd}]"
  end

  reply_to = ->(m : MessageIndex::Message) do
    addr = "#{m.from} <#{m.from.downcase.gsub(' ', '.')}@example.com>"
    goto_compose.call(addr, "Re: #{m.subject}", "body")
    nil
  end

  expunge = -> do
    deleted = messages.count { |m| flags_of[m].includes?("Deleted") }
    if deleted.zero?
      show_status.call "[No deleted messages to expunge]"
    else
      ask_yes_no.call("Expunge the #{deleted} deleted message#{deleted == 1 ? "" : "s"}? ", -> do
        messages.reject! { |m| flags_of[m].includes?("Deleted") }
        index.set_messages messages
        header.info.content = "Folder: INBOX  #{messages.size} Messages  (by #{current_sort})"
        show_status.call "[Expunged #{deleted} message#{deleted == 1 ? "" : "s"}]"
        nil
      end)
    end
    nil
  end

  # ----------------------------------------------------- Alpine key shortcuts
  #
  # The screen-level handler sees every keypress before the focused widget, so
  # these global commands work even with a list or text field focused. Each
  # screen has its own command set, matching the bottom KeyMenu.

  s.on(Event::KeyPress) do |e|
    ch = e.char
    key = e.key

    if key == Tput::Key::CtrlQ
      s.destroy
      exit
    end

    # While a yes/no prompt is up it owns the keyboard: its own handler
    # processes Y/N, swallow everything else here, Escape means "no".
    if prompt_active
      dismiss_prompt.call if key == Tput::Key::Escape
      next
    end

    # Escape goes "back" one screen, mirroring '<'. Compose keeps its own
    # Escape (cancel), handled below. Mid inline-edit, Escape must cancel the
    # edit (handled by OptionList itself), not exit the Config screen.
    if key == Tput::Key::Escape && current != :compose
      handled = true
      case current
      when :config
        if config.editing?
          handled = false
        else
          goto_setup.call
        end
      when :sort                                      then goto_index.call
      when :flag                                      then flagpick.confirm
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
      when 'q', 'Q' then ask_yes_no.call("Really quit ALPINE? ", -> { s.destroy; exit })
      when '?'      then goto_help.call
      end
    when :index
      case ch
      when '<', 'l', 'L' then goto_main.call
      when 'v', 'V', '>' then index.selected_message.try { |m| open_message.call(m) }
      when 'c', 'C'      then goto_compose.call("", "", "to")
      when 'n', 'N'      then index.down
      when 'p', 'P'      then index.up
      when 'r', 'R'      then index.selected_message.try { |m| reply_to.call(m) }
      when '$'           then goto_sort.call
      when '*'           then goto_flag.call
      when 'x', 'X'      then expunge.call
      when 'd', 'D'
        index.selected_message.try do |m|
          flags_of[m] << "Deleted"
          apply_flags.call m
          index.set_messages messages
          show_status.call "[Message marked for deletion]"
        end
      when 'u', 'U'
        index.selected_message.try do |m|
          flags_of[m].delete "Deleted"
          apply_flags.call m
          index.set_messages messages
          show_status.call "[Message undeleted]"
        end
      when 'q', 'Q' then ask_yes_no.call("Really quit ALPINE? ", -> { s.destroy; exit })
      when '?'      then goto_help.call
      end
    when :view
      case ch
      when '<', 'i', 'I' then goto_index.call
      when 'n', 'N'
        ni = index.selected + 1
        messages[ni]?.try { |m| open_message.call(m) } if ni < messages.size
      when 'p', 'P'
        pi = index.selected - 1
        messages[pi]?.try { |m| open_message.call(m) } if pi >= 0
      when 'r', 'R' then messages[index.selected]?.try { |m| reply_to.call(m) }
      when 'd', 'D'
        messages[index.selected]?.try do |m|
          flags_of[m] << "Deleted"
          apply_flags.call m
          index.set_messages messages
          show_status.call "[Message marked for deletion]"
        end
      when '?' then goto_help.call
      end
    when :compose
      case key
      when Tput::Key::CtrlX
        vals = compose.values
        run_progress.call "Sending message..."
        goto_main.call
        show_status.call %([Message to "#{vals["to"].empty? ? "(nobody)" : vals["to"]}" sent])
      when Tput::Key::CtrlT
        goto_attach.call
      when Tput::Key::CtrlG
        goto_help.call
      when Tput::Key::CtrlO
        goto_main.call
        show_status.call "[Message postponed]"
      when Tput::Key::CtrlC, Tput::Key::Escape
        goto_main.call
        show_status.call "[Compose cancelled]"
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
      when '<' then flagpick.confirm
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

  # One synchronous render so the Border frame is arranged before the first
  # view is shown and focused (see `show_only`).
  s._render
  goto_main.call
  s.exec
end
