require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

# Proof-of-concept Mutt-style TUI mail client built from the
# `Crysterm::Widget::Mutt` widget set plus stock Crysterm widgets. All content
# is mocked; nothing is read from disk or sent over the network. Where the Pine
# demo reproduces Alpine, this reproduces Mutt's look and keyboard-driven feel:
#
#   INDEX     the sidebar (mailbox list) beside the threaded message index
#   PAGER     read a message (arrows / PageUp / PageDown to scroll)
#   COMPOSE   Mutt's header-menu composer with an attachment list
#   HELP      a scrollable help pane
#
# The distinctive Mutt chrome is all here: the sidebar with unread counts, the
# threaded index with tree glyphs, the dashed status line, and a command line
# that prompts at the bottom (edit a header, confirm quit, …).
#
# The program is split in two files. `ui.cr` is the reusable part: `MuttUI`
# builds the frame (a `Border` layout with a `Stack` center and a nested `VBox`
# footer) and offers the chrome helpers — show a page, set the help line, run a
# command-line prompt. This file is the client: the mock mailbox, the screen
# flows and the Mutt key bindings. To build your own Mutt-style app, keep
# `ui.cr` and replace this file.
#
# Run with:  crystal examples/mutt/mutt.cr   (TERM=xterm-256color recommended)
include Tput::Namespace

# The Mutt widget pack's alias set (Sidebar, MessageIndex, Compose, …).
include CT::Widget::Mutt::DSL

require "./ui"

s = CT::Window.new(
  always_propagated_keys: [Tput::Key::CtrlQ],
  title: "Crysterm — Mutt-style demo",
  # Opt out of the app-global "q / Ctrl-Q hard-exits" default so `q` is ours
  # alone: on the index it opens the quit confirmation, on the pager/compose
  # it means "back". Ctrl-Q is still an explicit escape hatch below.
  #
  # `Application#route_input` applies the default quit *after* dispatch, and
  # only to a key no one `accept`ed — so the index's `q` (which accepts) would
  # survive it either way. The pager/compose/help `q` branches don't accept,
  # though, and would fall through to a hard exit. Opting out once is clearer
  # than sprinkling `accept` across every branch.
  default_quit_keys: false,
)

# This app drives Tab itself (index ⇄ sidebar; see the key handler), so turn
# off the framework's default Tab/Shift-Tab focus cycling. Otherwise the two
# fight over Tab, and the framework would rotate focus through *every* keyable
# widget — including the message editor on a non-current `Stack` page — landing
# keyboard focus (and the caret) in a pane that isn't on screen.
s.tab_navigation = false

# ----------------------------------------------------------------- mock data
#
# A single mail thread plus a couple of standalone messages, so the index can
# show off the thread tree. `depth` drives the tree glyphs (0 = thread root).

messages = [
  Message.new("Crysterm Demo", "THIS IS A VISUAL MOCKUP — NO REAL MAIL, DISK, OR NETWORK ACCESS",
    date: "Jul 13", size: 0, status: "N!", unread: true),
  Message.new("Mutt Team", "Welcome to Mutt!", date: "Jun 18", size: 1_234, status: "N", unread: true),
  Message.new("John Smith", "Project update", date: "Jun 19", size: 5_678),
  Message.new("Jane Doe", "Re: Project update", date: "Jun 19", size: 842, status: "r", depth: 1),
  Message.new("John Smith", "Re: Project update", date: "Jun 20", size: 1_120, status: "r", depth: 2),
  Message.new("Jane Doe", "Re: Project update", date: "Jun 20", size: 990, status: "r", depth: 1),
  Message.new("Crystal Weekly", "Issue #412: Macros deep-dive", date: "Jun 21", size: 9_002, status: "*"),
  Message.new("Security Team", "Rotate your keys", date: "Jun 22", size: 4_096, status: "N!", unread: true),
  Message.new("Mailer Daemon", "Undelivered Mail Returned", date: "Jun 20", size: 3_405, status: "D"),
]

bodies = [
  "** THIS IS A VISUAL DEMO — ALL CONTENT IS IN MEMORY **\n\n" \
  "There is NO real mail, and NO disk or network access. Nothing you type\n" \
  "is ever sent or saved. Composing, replying, deleting and \"sending\" only\n" \
  "update in-memory data to demonstrate the interface.\n\n" \
  "This is a proof-of-concept Mutt-style client built from the\n" \
  "Crysterm::Widget::Mutt widgets (Sidebar, threaded MessageIndex, StatusBar,\n" \
  "Compose) plus stock Crysterm widgets and layout engines.\n\n" \
  "Press 'm' to compose, 'r' to reply, arrows to move, '?' for help.\n",
  "Welcome to Mutt, reimagined in Crystal!\n\n" \
  "This is a proof-of-concept interface built from the\n" \
  "Crysterm::Widget::Mutt widget set: Sidebar, MessageIndex (threaded),\n" \
  "StatusBar and Compose, together with stock Crysterm widgets and\n" \
  "layout engines.\n\nPress 'i' to return to the index, or 'r' to reply.\n",
  "Hi team,\n\nHere's the weekly project update. Everything is on track\n" \
  "and we should hit the milestone on time.\n\nBest,\nJohn\n",
  "> Everything is on track\n\nGreat news! One question about the timeline...\n\nJane\n",
  "> One question about the timeline\n\nGood point — let me clarify below.\n\nJohn\n",
  "Thanks both. Let's sync on Friday.\n\nJane\n",
  "This week in Crystal:\n\n  * A deep dive into macros and AST nodes\n" \
  "  * Shards worth watching\n  * Performance tips for the compiler\n",
  "Our records show you have not rotated your access keys in 90 days.\n\n" \
  "Please rotate them at your earliest convenience.\n\n-- The Security Team\n",
  "This is an automatically generated delivery status notification.\n\n" \
  "Delivery to the following recipient failed permanently:\n\n" \
  "    nonexistent@example.invalid\n",
]

body_of = {} of Message => String
messages.each_with_index { |m, i| body_of[m] = bodies[i]? || "" }

# A message is "deleted" when its status includes 'D'; the index shows that in
# the flags column and `$` (sync) expunges them.
is_deleted = ->(m : Message) { m.status.includes?('D') }

mailboxes = [
  Mailbox.new("INBOX", messages.count(&.unread?), messages.size),
  Mailbox.new("lists", depth: 0),
  Mailbox.new("crystal", 12, 340, depth: 1, new: true),
  Mailbox.new("mutt", 0, 88, depth: 1),
  Mailbox.new("Sent", 0, 210),
  Mailbox.new("Drafts", 1, 1),
  Mailbox.new("Trash", 0, 14),
  Mailbox.new("Archive", 0, 1_902),
]

HELP_TEXT = <<-HELP
  {bold}Crysterm — Mutt-style demo{/bold}

  Everything here is mocked to show the Crysterm::Widget::Mutt widgets and
  Mutt's keyboard-driven navigation. There is no disk or network access.

  {bold}Index{/bold}
    j / Down     Next message        k / Up    Previous message
    Enter / i    Read message        m         Compose (mail) new
    r            Reply               d / u     Delete / undelete
    Tab          Move to the sidebar $         Sync (expunge deleted)
    c            Change folder (sidebar)       q  Quit    ? Help

  {bold}Sidebar{/bold} (after Tab)
    j / k        Highlight next / previous mailbox
    Enter        Open the highlighted mailbox

  {bold}Pager{/bold}
    Up/Down, PageUp/PageDown, Home/End    Scroll
    n / p        Next / previous message   i / q  Back to the index

  {bold}Compose{/bold} (m to write, r to reply)
    Mutt asks To: then Subject: on the command line, then opens the message
    editor. Ctrl-X leaves the editor for the compose menu.
    {bold}In the editor{/bold}   type freely; Ctrl-X done, Ctrl-C abort
    {bold}In the menu{/bold}     t/c/s/b To/Cc/Subject/Bcc
                     a attach   y send   q abort

  Press 'i' or 'q' to return to the index.
  HELP

# ------------------------------------------------------------------- the UI

ui = MuttUI.new(s, mailboxes: mailboxes, messages: messages, help_text: HELP_TEXT)
ui.sidebar.open_index = 0

# ---------------------------------------------------- screen state & helpers

current = :index
active_pane = :index # :index or :sidebar, on the index screen
current_folder = "INBOX"
quit_pending = false

# The message being composed. These are the single source of truth; the
# compose menu is rebuilt from them so edits survive re-opening the body
# editor. Mutt's compose flow fills To/Subject up front, then the body, then
# shows the menu where everything can still be changed before sending.
draft_to = ""
draft_cc = ""
draft_bcc = ""
draft_subject = ""
draft_body = ""
draft_attachments = [] of Attachment

# Left status text for the index screen: mailbox, message and new counts.
index_status = -> do
  newc = messages.count(&.unread?)
  delc = messages.count { |m| is_deleted.call m }
  left = "-*-Mutt: #{current_folder} [Msgs:#{messages.size}"
  left += " New:#{newc}" if newc > 0
  left += " Del:#{delc}" if delc > 0
  left += "]"
  ui.status.set_text left, "-(threads/date)-(all)-"
end

# ----------------------------------------------------------- the screen flows

goto_index = -> do
  current = :index
  active_pane = :index
  ui.show_page :index, ui.index
  ui.set_help "{bold}q{/bold}:Quit {bold}?{/bold}:Help {bold}m{/bold}:Mail " \
              "{bold}r{/bold}:Reply {bold}Enter{/bold}:Read {bold}d{/bold}:Del " \
              "{bold}u{/bold}:Undel {bold}${/bold}:Sync {bold}Tab{/bold}:Sidebar"
  index_status.call
  ui.show_message %(#{messages.size} messages, #{messages.count(&.unread?)} new)
  nil
end

open_message = ->(m : Message) do
  i = messages.index(m) || 0
  ui.index.current_index = i
  m.unread = false
  m.status = m.status.gsub('N', "")
  header = String.build do |b|
    b << "{bold}Date:{/bold}    #{m.date}\n"
    b << "{bold}From:{/bold}    #{m.from} <#{m.from.downcase.gsub(' ', '.')}@example.com>\n"
    b << "{bold}To:{/bold}      you@example.com\n"
    b << "{bold}Subject:{/bold} #{m.subject}\n\n"
  end
  ui.pager.content = header + (body_of[m]? || "")
  current = :pager
  ui.show_page :pager, ui.pager
  ui.set_help "{bold}i{/bold}:Back {bold}Up/Dn{/bold}:Scroll {bold}n{/bold}:Next " \
              "{bold}p{/bold}:Prev {bold}r{/bold}:Reply {bold}d{/bold}:Del {bold}q{/bold}:Quit"
  ui.status.set_text "-*-Mutt: #{m.subject}", "-(#{i + 1}/#{messages.size})-"
  ui.show_message %(Reading message #{i + 1} of #{messages.size})
  nil
end

open_folder = ->(mb : Mailbox) do
  idx = ui.sidebar.mailboxes.index(mb) || 0
  ui.sidebar.open_index = idx
  current_folder = mb.name
  if mb.name == "INBOX"
    ui.index.messages = messages
  else
    ui.index.messages = [] of Message
  end
  active_pane = :index
  ui.index.focus
  index_status.call
  ui.show_message(mb.name == "INBOX" ? %(Opened "INBOX") : %(Mailbox "#{mb.name}" is empty in this demo))
  nil
end

# Open the body editor; Ctrl-X (handled in the key loop) finishes and lands on
# the compose menu.
open_editor = ->(initial : String) do
  ui.editor.value = initial
  current = :editor
  ui.show_page :editor, ui.editor
  ui.set_help "{bold}^X{/bold}:Done (to compose menu)   write your message below"
  ui.status.set_text "-*-Mutt: Editing message", "-(body)-"
  ui.show_message "Type your message. Press Ctrl-X when you're done."
  nil
end

# Show the compose menu, rebuilt from the draft so header/attachment edits and
# re-editing the body all round-trip. The body is Mutt's first attachment.
open_compose_menu = -> do
  compose = ui.compose
  compose.reset
  compose.set_header "From", "you@example.com"
  compose.set_header "To", draft_to
  compose.set_header "Cc", draft_cc
  compose.set_header "Bcc", draft_bcc
  compose.set_header "Subject", draft_subject
  compose.add_attachment Attachment.new("(message body)", "text/plain", draft_body.bytesize, "inline")
  draft_attachments.each { |a| compose.add_attachment a }
  current = :compose
  ui.show_page :compose, compose.menu
  ui.set_help "{bold}y{/bold}:Send {bold}q{/bold}:Abort {bold}t{/bold}:To " \
              "{bold}c{/bold}:Cc {bold}s{/bold}:Subj {bold}b{/bold}:Bcc " \
              "{bold}a{/bold}:Attach"
  ui.status.set_text "-*-Mutt: Compose", "-(#{compose.attachments.size} att)-"
  ui.show_message "y send, t/c/s/b edit headers, a attach, q abort"
  nil
end

# Edit one compose header via a command-line prompt, then rebuild the menu.
# Shared by the header command keys (t/c/s/b, which pass their triggering
# keypress so it can be `accept`ed) and by Enter/click on a header row (which
# pass `nil`). From is display-only here, so it has no prompt.
edit_field = ->(field : String, e : CT::Event::KeyPress?) do
  case field
  when "To"
    ui.open_prompt("To: ", draft_to, e) { |v| draft_to = v; open_compose_menu.call }
  when "Cc"
    ui.open_prompt("Cc: ", draft_cc, e) { |v| draft_cc = v; open_compose_menu.call }
  when "Bcc"
    ui.open_prompt("Bcc: ", draft_bcc, e) { |v| draft_bcc = v; open_compose_menu.call }
  when "Subject"
    ui.open_prompt("Subject: ", draft_subject, e) { |v| draft_subject = v; open_compose_menu.call }
  else
    e.try &.accept
  end
  nil
end

# Enter (or a click) on a compose-menu row: edit that header, or — on the body,
# which is always the first attachment — re-open the editor seeded with the
# current draft. Arrow keys already move the highlight through every row
# (`Compose` is one `List` whose `-- Attachments --` divider is non-selectable),
# so this makes the menu fully usable by cursor as well as by command key.
ui.compose.menu.on(CT::Event::ItemActivated) do
  kind, sub = ui.compose.selected_row
  case kind
  when Compose::RowKind::Header
    edit_field.call Compose::FIELDS[sub], nil
  when Compose::RowKind::Attachment
    if sub == 0
      open_editor.call draft_body
    else
      ui.show_message "Attachment: #{ui.compose.attachments[sub].filename}"
    end
  end
end

# `m`: fresh message. Mutt asks To, then Subject, then opens the editor.
#
# Two questions in a row, written as two statements: `Window#prompt` parks the
# calling fiber until the user answers (`nil` when cancelled) instead of
# handing the answer to a callback, so the sequence stays flat. It must not run
# on the fiber delivering input — which is the one this key handler is on —
# hence the `spawn`.
start_compose = ->(e : CT::Event::KeyPress?) do
  e.try &.accept
  draft_to = ""
  draft_cc = ""
  draft_bcc = ""
  draft_subject = ""
  draft_body = ""
  draft_attachments = [] of Attachment
  spawn do
    if (to = s.prompt "To: ") && (subject = s.prompt "Subject: ")
      draft_to = to
      draft_subject = subject
      open_editor.call ""
    end
  end
  nil
end

# `r`: reply. To/Subject are pre-filled and the body editor opens seeded with
# the `> `-quoted original — the essential Mutt reply behavior.
reply_to = ->(m : Message) do
  draft_to = "#{m.from} <#{m.from.downcase.gsub(' ', '.')}@example.com>"
  draft_subject = m.subject.starts_with?("Re: ") ? m.subject : "Re: #{m.subject}"
  draft_cc = ""
  draft_bcc = ""
  quoted = (body_of[m]? || "").lines.map { |l| "> #{l}" }.join('\n')
  draft_body = "On #{m.date}, #{m.from} wrote:\n#{quoted}\n\n"
  draft_attachments = [] of Attachment
  open_editor.call draft_body
  nil
end

goto_help = -> do
  current = :help
  ui.show_page :help, ui.help
  ui.set_help "{bold}i{/bold}:Back {bold}q{/bold}:Back {bold}Up/Dn{/bold}:Scroll " \
              "{bold}PgUp/PgDn{/bold}:Page"
  ui.status.set_text "-*-Mutt: Help", "-(help)-"
  ui.show_message "Help — press i or q to return to the index"
  nil
end

# ------------------------------------------------------------- wiring it up

messages.each { |m| m.callback { open_message.call m } }
ui.sidebar.mailboxes.each { |mb| mb.callback { open_folder.call mb } }

# Mailbox click / Enter in the sidebar hands focus back to the index.
ui.sidebar.on(CT::Event::ItemActivated) { active_pane = :index }

# ----------------------------------------------------- Mutt key shortcuts
#
# The window's built-in dispatcher runs *before* this handler (it is installed
# in `Window#initialize`, and handlers fire in registration order) — it is what
# forwards arrows/Enter to the focused pane for its own navigation + callbacks.
# This handler runs afterwards on the same event, so the Mutt command letters
# work whichever pane holds focus.

s.on(CT::Event::KeyPress) do |e|
  ch = e.char
  key = e.key

  if key == Tput::Key::CtrlQ
    # Graceful app-level quit — see `Window#quit` (vs a bare `exit`).
    s.quit
  end

  # A pending yes/no confirmation (e.g. quit) is a single-keypress prompt, the
  # way Mutt's `mutt_yesorno` works: 'y' or Enter confirms, anything else
  # cancels — no line editing, no focus juggling. Handled up front so it can't
  # be mistaken for a command on the current screen.
  if quit_pending
    quit_pending = false
    if ch == 'y' || ch == 'Y' || key == Tput::Key::Enter
      # Graceful app-level quit — see `Window#quit` (vs a bare `exit`).
      s.quit
    end
    goto_index.call
    ui.show_message "Quit aborted"
    e.accept
    next
  end

  # While the command-line prompt is up it owns the keyboard; only Escape
  # (cancel) is handled here — everything else flows to the LineEdit.
  if ui.prompt_active?
    if key == Tput::Key::Escape
      ui.finish_prompt
      goto_index.call if current == :index
      (current == :compose) ? ui.compose.menu.focus : nil
      ui.show_message "Cancelled"
    end
    next
  end

  case current
  when :index
    # Tab toggles which pane (index / sidebar) is focused and drives navigation.
    if key == Tput::Key::Tab
      if active_pane == :index
        active_pane = :sidebar
        ui.sidebar.focus
        ui.show_message "Sidebar: j/k to move, Enter to open a mailbox, Tab back"
      else
        active_pane = :index
        ui.index.focus
        ui.show_message "Index"
      end
      next
    end

    case ch
    when '?' then goto_help.call
    when 'q', 'Q'
      # Mutt-style single-key confirmation on the bottom command line.
      quit_pending = true
      ui.show_message "Quit Mutt? ([yes]/no): "
      e.accept
    when 'm' then start_compose.call e
    when 'c'
      # Change folder: hand focus to the sidebar to pick a mailbox.
      active_pane = :sidebar
      ui.sidebar.focus
      ui.show_message "Select a mailbox and press Enter"
    when 'r', 'R' then (active_pane == :index) && ui.index.selected_message.try { |m| reply_to.call m }
    when '$'
      before = messages.size
      messages.reject! { |m| is_deleted.call m }
      ui.index.messages = messages
      index_status.call
      ui.show_message "Expunged #{before - messages.size} message(s)"
    when 'd', 'D'
      if active_pane == :index
        ui.index.selected_message.try do |m|
          m.status = "D" + m.status.gsub('D', "")
          ui.index.messages = messages
          index_status.call
          ui.show_message "Message marked for deletion"
        end
      end
    when 'u', 'U'
      if active_pane == :index
        ui.index.selected_message.try do |m|
          m.status = m.status.gsub('D', "")
          ui.index.messages = messages
          index_status.call
          ui.show_message "Message undeleted"
        end
      end
    end
  when :pager
    case ch
    when 'i', 'q', 'Q' then goto_index.call
    when 'n'
      ni = ui.index.current_index + 1
      messages[ni]?.try { |m| open_message.call m } if ni < messages.size
    when 'p'
      pi = ui.index.current_index - 1
      messages[pi]?.try { |m| open_message.call m } if pi >= 0
    when 'r', 'R' then messages[ui.index.current_index]?.try { |m| reply_to.call m }
    when '?'      then goto_help.call
    when 'd', 'D'
      messages[ui.index.current_index]?.try do |m|
        m.status = "D" + m.status.gsub('D', "")
        ui.show_message "Message marked for deletion"
      end
    end
  when :editor
    # The body editor grabs the keyboard (it is `input_on_focus`); this
    # window-level handler still sees every key, so Ctrl-X / Ctrl-C work
    # without the editor consuming them.
    case key
    when Tput::Key::CtrlX
      draft_body = ui.editor.value
      open_compose_menu.call
      e.accept
    when Tput::Key::CtrlC
      goto_index.call
      ui.show_message "Compose aborted"
      e.accept
    end
  when :compose
    # Edits update the draft (the source of truth) and rebuild the menu, so
    # they survive re-opening the body editor.
    case ch
    when 'y', 'Y'
      to = draft_to
      goto_index.call
      ui.show_message %(Message to "#{to.empty? ? "(nobody)" : to}" sent)
    when 'q', 'Q'
      goto_index.call
      ui.show_message "Compose aborted"
    when 't' then edit_field.call "To", e
    when 'c' then edit_field.call "Cc", e
    when 'b' then edit_field.call "Bcc", e
    when 's' then edit_field.call "Subject", e
    when 'a'
      draft_attachments << Attachment.new("patch.diff", "text/x-diff", 4_096)
      open_compose_menu.call
      ui.show_message "Attached patch.diff"
    when '?' then goto_help.call
    end
  when :help
    case ch
    when 'i', 'q', 'Q' then goto_index.call
    end
  end
end

goto_index.call
s.exec
