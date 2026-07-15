require "../../src/crysterm"

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
# As in the Pine demo, every widget is positioned by a *layout* (a `Border`
# frame with a nested `VBox` footer), never by fixed top/left/width/height. Where
# Pine switches its body views by visibility, the center here is a `Stack`.
#
# Run with:  crystal examples/mutt/mutt.cr   (TERM=xterm-256color recommended)
module Crysterm
  include Tput::Namespace
  include Widgets

  alias Sidebar = Widget::Mutt::Sidebar
  alias Mailbox = Widget::Mutt::Mailbox
  alias MessageIndex = Widget::Mutt::MessageIndex
  alias Message = Widget::Mutt::Message
  alias StatusBar = Widget::Mutt::StatusBar
  alias Compose = Widget::Mutt::Compose
  alias Attachment = Widget::Mutt::Attachment

  s = Window.new(
    always_propagate: [Tput::Key::CtrlQ],
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

  # ------------------------------------------------------------- the frame
  #
  # A single Border layout carves the terminal into Mutt's regions: a help line
  # on top, the sidebar (plus a divider) on the left, the switchable main area
  # in the center, and a two-row footer (status line + command line) at the
  # bottom. No widget below is given a fixed position.

  frame = Widget::Box.new(parent: s, width: "100%", height: "100%", layout: Layout::Border.new)

  # Top: Mutt's one-line command hint bar (updated per screen).
  helpline = Widget::Box.new(
    parent: frame, height: 1, parse_tags: true,
    style: Style.new(reverse: true),
    layout_hint: :top,
  )

  # Left: the sidebar, then a one-column divider (Mutt's sidebar_divider_char).
  sidebar = Sidebar.new(parent: frame, width: 24, mailboxes: mailboxes,
    layout_hint: :left)
  sidebar.open = 0
  Widget::VLine.new(parent: frame, width: 1, layout_hint: :left)

  # Center: the switchable main area, arranged by a `Stack` layout (Qt's
  # `QStackedLayout`) — all views fill the center; only `stack.current_index` renders,
  # the rest are suppressed. This is what lets the `editor` (a `PlainTextEdit`,
  # Mutt's `$editor` message pane) paint: unlike a StackedWidget, the Stack
  # layout lays a view out freshly when it becomes current, and it suppresses
  # the others cleanly (no stale cells bleeding through).
  stack = Layout::Stack.new
  center = Widget::Box.new(parent: frame, layout: stack, layout_hint: :center)
  index = MessageIndex.new(parent: center, messages: messages)
  pager = Widget::ScrollableText.new(parent: center, parse_tags: true, keys: true)
  # `shrink_to_fit: false` so the editor fills the whole center area instead of
  # shrinking to the width/height of what's typed (a `PlainTextEdit` includes
  # `Mixin::Interactive`, which defaults `shrink_to_fit = true` — shrink-to-content).
  # Mutt's message editor occupies the entire body pane.
  editor = Widget::PlainTextEdit.new(parent: center, input_on_focus: true,
    shrink_to_fit: false, width: "100%", height: "100%")
  compose = Compose.new(parent: center)
  help = Widget::ScrollableText.new(parent: center, parse_tags: true, keys: true, content: HELP_TEXT)
  PAGE = {index: 0, pager: 1, editor: 2, compose: 3, help: 4}

  # Bottom: a two-row footer stacked by a VBox — status line above, command
  # line below. The command line is an HBox of a label zone (transient status,
  # or a prompt like "To:") and, during a text prompt, an inline editor to its
  # right — Mutt does all its prompting right here on the bottom line.
  footer = Widget::Box.new(parent: frame, height: 2, layout: Layout::VBox.new,
    layout_hint: :bottom)
  status = StatusBar.new
  footer.append status
  cmdline = Widget::Box.new(height: 1, width: "100%", layout: Layout::HBox.new)
  footer.append cmdline
  # `cmd_label` fills the line for plain messages; for a prompt it shrinks to the
  # label width and `cmd_input` (flex) fills the rest.
  cmd_label = Widget::Box.new(height: 1, parse_tags: true)
  cmd_input = Widget::LineEdit.new(height: 1, visible: false)
  cmdline.append cmd_label, cmd_input

  # ---------------------------------------------------- screen state & helpers

  current = :index
  active_pane = :index # :index or :sidebar, on the index screen
  current_folder = "INBOX"
  prompt_active = false
  prompt_done = nil.as(Proc(String, Nil)?)
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

  # Show a transient status message on the command line: the label zone fills
  # the whole line, the inline editor stands down.
  show_message = ->(text : String) do
    cmd_input.hide
    cmd_label.content = text
    cmd_label.width = nil
    nil
  end

  # Left status text for the index screen: mailbox, message and new counts.
  index_status = -> do
    newc = messages.count(&.unread?)
    delc = messages.count { |m| is_deleted.call m }
    left = "-*-Mutt: #{current_folder} [Msgs:#{messages.size}"
    left += " New:#{newc}" if newc > 0
    left += " Del:#{delc}" if delc > 0
    left += "]"
    status.set left, "-(threads/date)-(all)-"
  end

  set_help = ->(text : String) { helpline.content = text; nil }

  # Raise one center view and focus it. Render *before* focusing so the view
  # (notably the editor) is laid out visible before it takes the keyboard.
  show_page = ->(name : Symbol, view : Widget) do
    current = name
    stack.current_index = PAGE[name]
    s._render
    view.focus
    nil
  end

  # ----------------------------------------------------------- the command line

  # Open a command-line prompt (Mutt asks for To/Subject/headers this way): the
  # bold label shrinks to its width on the left, the inline editor fills the rest
  # of the line, and *on_done* runs with the submitted value.
  #
  # *e* is the keypress that triggered the prompt. Accepting it marks the key
  # consumed, which is what stops `Application#route_input` from also treating a
  # command letter as the app-global quit key.
  open_prompt = ->(label : String, initial : String, e : ::Crysterm::Event::KeyPress?, on_done : Proc(String, Nil)) do
    prompt_active = true
    prompt_done = on_done
    cmd_label.content = "{bold}#{label}{/bold}"
    cmd_label.width = label.size
    cmd_input.value = initial
    cmd_input.show
    # Lay the command line out *before* focusing the field. `cmd_input` was
    # hidden, so the enclosing HBox has not yet given it a column or a width —
    # those are assigned during a render. Focusing first would run `read_input`
    # → `_update_cursor` against unresolved geometry and park the caret at
    # column 0, over the label. One synchronous render settles the layout so the
    # caret lands in the field — the same render-before-focus order `show_page`
    # relies on. (`focus` itself schedules the repaint that paints the field in
    # its focused styling, so only this one render has to be explicit.)
    s._render
    cmd_input.focus
    e.try &.accept
    nil
  end

  finish_prompt = -> do
    prompt_active = false
    prompt_done = nil
    cmd_input.value = ""
    cmd_input.hide
    nil
  end

  cmd_input.on(::Crysterm::Event::Submit) do
    if prompt_active
      value = cmd_input.value
      done = prompt_done
      finish_prompt.call
      done.try &.call(value)
    end
  end

  # ----------------------------------------------------------- the screen flows

  goto_index = -> do
    current = :index
    active_pane = :index
    show_page.call :index, index
    set_help.call "{bold}q{/bold}:Quit {bold}?{/bold}:Help {bold}m{/bold}:Mail " \
                  "{bold}r{/bold}:Reply {bold}Enter{/bold}:Read {bold}d{/bold}:Del " \
                  "{bold}u{/bold}:Undel {bold}${/bold}:Sync {bold}Tab{/bold}:Sidebar"
    index_status.call
    show_message.call %(#{messages.size} messages, #{messages.count(&.unread?)} new)
    nil
  end

  open_message = ->(m : Message) do
    i = messages.index(m) || 0
    index.current_index = i
    m.unread = false
    m.status = m.status.gsub('N', "")
    header = String.build do |b|
      b << "{bold}Date:{/bold}    #{m.date}\n"
      b << "{bold}From:{/bold}    #{m.from} <#{m.from.downcase.gsub(' ', '.')}@example.com>\n"
      b << "{bold}To:{/bold}      you@example.com\n"
      b << "{bold}Subject:{/bold} #{m.subject}\n\n"
    end
    pager.set_content header + (body_of[m]? || "")
    show_page.call :pager, pager
    set_help.call "{bold}i{/bold}:Back {bold}Up/Dn{/bold}:Scroll {bold}n{/bold}:Next " \
                  "{bold}p{/bold}:Prev {bold}r{/bold}:Reply {bold}d{/bold}:Del {bold}q{/bold}:Quit"
    status.set "-*-Mutt: #{m.subject}", "-(#{i + 1}/#{messages.size})-"
    show_message.call %(Reading message #{i + 1} of #{messages.size})
    nil
  end

  open_folder = ->(mb : Mailbox) do
    idx = sidebar.mailboxes.index(mb) || 0
    sidebar.open = idx
    current_folder = mb.name
    if mb.name == "INBOX"
      index.messages = messages
    else
      index.messages = [] of Message
    end
    active_pane = :index
    index.focus
    index_status.call
    show_message.call(mb.name == "INBOX" ? %(Opened "INBOX") : %(Mailbox "#{mb.name}" is empty in this demo))
    nil
  end

  # Open the body editor; Ctrl-X (handled in the key loop) finishes and lands on
  # the compose menu. The editor is a `PlainTextEdit`: it only paints once it has
  # been laid out while visible, so make it visible and force a *synchronous*
  # render before giving it focus (doing this here, inside `exec`, means the
  # terminal size is known and the layout is real).
  open_editor = ->(initial : String) do
    editor.value = initial
    show_page.call :editor, editor
    set_help.call "{bold}^X{/bold}:Done (to compose menu)   write your message below"
    status.set "-*-Mutt: Editing message", "-(body)-"
    show_message.call "Type your message. Press Ctrl-X when you're done."
    nil
  end

  # Show the compose menu, rebuilt from the draft so header/attachment edits and
  # re-editing the body all round-trip. The body is Mutt's first attachment.
  open_compose_menu = -> do
    compose.reset
    compose.set_header "From", "you@example.com"
    compose.set_header "To", draft_to
    compose.set_header "Cc", draft_cc
    compose.set_header "Bcc", draft_bcc
    compose.set_header "Subject", draft_subject
    compose.add_attachment Attachment.new("(message body)", "text/plain", draft_body.bytesize, "inline")
    draft_attachments.each { |a| compose.add_attachment a }
    show_page.call :compose, compose.menu
    set_help.call "{bold}y{/bold}:Send {bold}q{/bold}:Abort {bold}t{/bold}:To " \
                  "{bold}c{/bold}:Cc {bold}s{/bold}:Subj {bold}b{/bold}:Bcc " \
                  "{bold}a{/bold}:Attach"
    status.set "-*-Mutt: Compose", "-(#{compose.attachments.size} att)-"
    show_message.call "y send, t/c/s/b edit headers, a attach, q abort"
    nil
  end

  # Edit one compose header via a command-line prompt, then rebuild the menu.
  # Shared by the header command keys (t/c/s/b, which pass their triggering
  # keypress so it can be `accept`ed) and by Enter/click on a header row (which
  # pass `nil`). From is display-only here, so it has no prompt.
  edit_field = ->(field : String, e : ::Crysterm::Event::KeyPress?) do
    case field
    when "To"
      open_prompt.call "To: ", draft_to, e, ->(v : String) { draft_to = v; open_compose_menu.call; nil }
    when "Cc"
      open_prompt.call "Cc: ", draft_cc, e, ->(v : String) { draft_cc = v; open_compose_menu.call; nil }
    when "Bcc"
      open_prompt.call "Bcc: ", draft_bcc, e, ->(v : String) { draft_bcc = v; open_compose_menu.call; nil }
    when "Subject"
      open_prompt.call "Subject: ", draft_subject, e, ->(v : String) { draft_subject = v; open_compose_menu.call; nil }
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
  compose.menu.on(::Crysterm::Event::ActionItem) do
    kind, sub = compose.selected_row
    case kind
    when Compose::RowKind::Header
      edit_field.call Compose::FIELDS[sub], nil
    when Compose::RowKind::Attachment
      if sub == 0
        open_editor.call draft_body
      else
        show_message.call "Attachment: #{compose.attachments[sub].filename}"
      end
    end
  end

  # `m`: fresh message. Mutt asks To, then Subject, then opens the editor.
  start_compose = ->(e : ::Crysterm::Event::KeyPress?) do
    draft_to = ""
    draft_cc = ""
    draft_bcc = ""
    draft_subject = ""
    draft_body = ""
    draft_attachments = [] of Attachment
    open_prompt.call "To: ", "", e, ->(to : String) do
      draft_to = to
      open_prompt.call "Subject: ", "", nil, ->(subj : String) do
        draft_subject = subj
        open_editor.call ""
        nil
      end
      nil
    end
    nil
  end

  # `r`: reply. To/Subject are pre-filled (the essential Mutt reply behavior),
  # then the body editor opens — empty, as Pine's composer does. (Seeding the
  # editor with a quoted original isn't shown: a pre-filled `PlainTextEdit`
  # entering `input_on_focus` read mode doesn't repaint its initial content.)
  reply_to = ->(m : Message) do
    draft_to = "#{m.from} <#{m.from.downcase.gsub(' ', '.')}@example.com>"
    draft_subject = m.subject.starts_with?("Re: ") ? m.subject : "Re: #{m.subject}"
    draft_cc = ""
    draft_bcc = ""
    draft_body = ""
    draft_attachments = [] of Attachment
    open_editor.call ""
    nil
  end

  goto_help = -> do
    show_page.call :help, help
    set_help.call "{bold}i{/bold}:Back {bold}q{/bold}:Back {bold}Up/Dn{/bold}:Scroll " \
                  "{bold}PgUp/PgDn{/bold}:Page"
    status.set "-*-Mutt: Help", "-(help)-"
    show_message.call "Help — press i or q to return to the index"
    nil
  end

  # ------------------------------------------------------------- wiring it up

  messages.each { |m| m.callback = -> { open_message.call m; nil } }
  sidebar.mailboxes.each { |mb| mb.callback = -> { open_folder.call mb; nil } }

  # Mailbox click / Enter in the sidebar hands focus back to the index.
  sidebar.on(::Crysterm::Event::ActionItem) { active_pane = :index }

  # ----------------------------------------------------- Mutt key shortcuts
  #
  # The window's built-in dispatcher runs *before* this handler (it is installed
  # in `Window#initialize`, and handlers fire in registration order) — it is what
  # forwards arrows/Enter to the focused pane for its own navigation + callbacks.
  # This handler runs afterwards on the same event, so the Mutt command letters
  # work whichever pane holds focus.

  s.on(::Crysterm::Event::KeyPress) do |e|
    ch = e.char
    key = e.key

    if key == Tput::Key::CtrlQ
      # App-level quit: emits `Event::AboutToQuit` (a save-state hook) and tears
      # every window down before exiting, rather than hard-exiting behind the
      # toolkit's back.
      (s.application || ::Crysterm::Application.global).quit
    end

    # A pending yes/no confirmation (e.g. quit) is a single-keypress prompt, the
    # way Mutt's `mutt_yesorno` works: 'y' or Enter confirms, anything else
    # cancels — no line editing, no focus juggling. Handled up front so it can't
    # be mistaken for a command on the current screen.
    if quit_pending
      quit_pending = false
      if ch == 'y' || ch == 'Y' || key == Tput::Key::Enter
        # App-level quit: emits `Event::AboutToQuit` (a save-state hook) and tears
        # every window down before exiting, rather than hard-exiting behind the
        # toolkit's back.
        (s.application || ::Crysterm::Application.global).quit
      end
      goto_index.call
      show_message.call "Quit aborted"
      e.accept
      next
    end

    # While the command-line prompt is up it owns the keyboard; only Escape
    # (cancel) is handled here — everything else flows to the LineEdit.
    if prompt_active
      if key == Tput::Key::Escape
        finish_prompt.call
        goto_index.call if current == :index
        (current == :compose) ? compose.menu.focus : nil
        show_message.call "Cancelled"
      end
      next
    end

    case current
    when :index
      # Tab toggles which pane (index / sidebar) is focused and drives navigation.
      if key == Tput::Key::Tab
        if active_pane == :index
          active_pane = :sidebar
          sidebar.focus
          show_message.call "Sidebar: j/k to move, Enter to open a mailbox, Tab back"
        else
          active_pane = :index
          index.focus
          show_message.call "Index"
        end
        next
      end

      case ch
      when '?' then goto_help.call
      when 'q', 'Q'
        # Mutt-style single-key confirmation on the bottom command line.
        quit_pending = true
        show_message.call "Quit Mutt? ([yes]/no): "
        e.accept
      when 'm' then start_compose.call e
      when 'c'
        # Change folder: hand focus to the sidebar to pick a mailbox.
        active_pane = :sidebar
        sidebar.focus
        show_message.call "Select a mailbox and press Enter"
      when 'r', 'R' then (active_pane == :index) && index.selected_message.try { |m| reply_to.call m }
      when '$'
        before = messages.size
        messages.reject! { |m| is_deleted.call m }
        index.messages = messages
        index_status.call
        show_message.call "Expunged #{before - messages.size} message(s)"
      when 'd', 'D'
        if active_pane == :index
          index.selected_message.try do |m|
            m.status = "D" + m.status.gsub('D', "")
            index.messages = messages
            index_status.call
            show_message.call "Message marked for deletion"
          end
        end
      when 'u', 'U'
        if active_pane == :index
          index.selected_message.try do |m|
            m.status = m.status.gsub('D', "")
            index.messages = messages
            index_status.call
            show_message.call "Message undeleted"
          end
        end
      end
    when :pager
      case ch
      when 'i', 'q', 'Q' then goto_index.call
      when 'n'
        ni = index.selected + 1
        messages[ni]?.try { |m| open_message.call m } if ni < messages.size
      when 'p'
        pi = index.selected - 1
        messages[pi]?.try { |m| open_message.call m } if pi >= 0
      when 'r', 'R' then messages[index.selected]?.try { |m| reply_to.call m }
      when '?'      then goto_help.call
      when 'd', 'D'
        messages[index.selected]?.try do |m|
          m.status = "D" + m.status.gsub('D', "")
          show_message.call "Message marked for deletion"
        end
      end
    when :editor
      # The body editor grabs the keyboard (it is `input_on_focus`); this
      # window-level handler still sees every key, so Ctrl-X / Ctrl-C work
      # without the editor consuming them.
      case key
      when Tput::Key::CtrlX
        draft_body = editor.value
        open_compose_menu.call
        e.accept
      when Tput::Key::CtrlC
        goto_index.call
        show_message.call "Compose aborted"
        e.accept
      end
    when :compose
      # Edits update the draft (the source of truth) and rebuild the menu, so
      # they survive re-opening the body editor.
      case ch
      when 'y', 'Y'
        to = draft_to
        goto_index.call
        show_message.call %(Message to "#{to.empty? ? "(nobody)" : to}" sent)
      when 'q', 'Q'
        goto_index.call
        show_message.call "Compose aborted"
      when 't' then edit_field.call "To", e
      when 'c' then edit_field.call "Cc", e
      when 'b' then edit_field.call "Bcc", e
      when 's' then edit_field.call "Subject", e
      when 'a'
        draft_attachments << Attachment.new("patch.diff", "text/x-diff", 4_096)
        open_compose_menu.call
        show_message.call "Attached patch.diff"
      when '?' then goto_help.call
      end
    when :help
      case ch
      when 'i', 'q', 'Q' then goto_index.call
      end
    end
  end

  # One synchronous render so the Border/Stack frame is arranged before the
  # first page is shown and focused (see `show_page`).
  s._render
  goto_index.call
  s.exec
end
