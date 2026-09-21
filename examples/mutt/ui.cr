# The reusable TUI of the Mutt-style client: the frame, its regions and the
# chrome helpers. Nothing here knows about mail, drafts or screens; the flows
# and key handling that use it live in mutt.cr. Relies on the aliases and
# includes declared there (`CT`, `CW`, `Tput::Namespace`, `Widget::Mutt::DSL`).
#
# A single Border layout carves the terminal into Mutt's regions: a help line
# on top, the sidebar (plus a divider) on the left, the switchable main area
# in the center, and a two-row footer (status line + command line) at the
# bottom. No widget is given a fixed position.
class MuttUI
  # Page names in the center `Stack`, by index.
  PAGE = {index: 0, pager: 1, editor: 2, compose: 3, help: 4}

  getter window : CT::Window

  # Top: Mutt's one-line command hint bar (updated per screen).
  getter helpline : CW::Box

  # Left: the mailbox list.
  getter sidebar : Sidebar

  # Center: the switchable main area and its pages.
  getter stack : CT::Layout::Stack
  getter index : MessageIndex
  getter pager : CW::ScrollableText
  getter editor : CW::PlainTextEdit
  getter compose : Compose
  getter help : CW::ScrollableText

  # Bottom: status line above the command line.
  getter status : StatusBar
  getter cmd_label : CW::Box
  getter cmd_input : CW::LineEdit

  # Whether a command-line prompt currently owns the keyboard.
  getter? prompt_active = false
  @prompt_done : Proc(String, Nil)? = nil

  def initialize(@window, *, mailboxes : Array(Mailbox), messages : Array(Message), help_text : String)
    frame = CW::Box.new(parent: @window, width: "100%", height: "100%", layout: CT::Layout::Dock.new)

    @helpline = CW::Box.new(
      parent: frame, height: 1, parse_tags: true,
      style: CT::Style.new(reverse: true),
      layout_hint: :top,
    )

    # The sidebar, then a one-column divider (Mutt's sidebar_divider_char).
    @sidebar = Sidebar.new(parent: frame, width: 24, mailboxes: mailboxes,
      layout_hint: :left)
    CW::VLine.new(parent: frame, width: 1, layout_hint: :left)

    # The main area is arranged by a `Stack` layout (Qt's `QStackedLayout`) —
    # all views fill the center; only `stack.current_index` renders, the rest
    # are suppressed. This is what lets the `editor` (a `PlainTextEdit`) paint:
    # unlike a StackedWidget, the Stack layout lays a view out freshly when it
    # becomes current, and it suppresses the others cleanly (no stale cells
    # bleeding through).
    @stack = CT::Layout::Stack.new
    center = CW::Box.new(parent: frame, layout: @stack, layout_hint: :center)
    @index = MessageIndex.new(parent: center, messages: messages)
    @pager = CW::ScrollableText.new(parent: center, parse_tags: true, keys: true)
    # `shrink_to_fit: false` so the editor fills the whole center area instead of
    # shrinking to the width/height of what's typed (a `PlainTextEdit` includes
    # `Mixin::Interactive`, which defaults `shrink_to_fit = true`).
    @editor = CW::PlainTextEdit.new(parent: center, input_on_focus: true,
      shrink_to_fit: false, width: "100%", height: "100%")
    @compose = Compose.new(parent: center)
    @help = CW::ScrollableText.new(parent: center, parse_tags: true, keys: true, content: help_text)

    # A two-row footer stacked by a VBox — status line above, command line
    # below. The command line is an HBox of a label zone (transient status, or
    # a prompt like "To:") and, during a text prompt, an inline editor to its
    # right — Mutt does all its prompting right here on the bottom line.
    footer = CW::Box.new(parent: frame, height: 2, layout: CT::Layout::VBox.new,
      layout_hint: :bottom)
    @status = StatusBar.new
    footer.append @status
    cmdline = CW::Box.new(height: 1, width: "100%", layout: CT::Layout::HBox.new)
    footer.append cmdline
    # `cmd_label` fills the line for plain messages; for a prompt it shrinks to
    # the label width and `cmd_input` (flex) fills the rest.
    @cmd_label = CW::Box.new(height: 1, parse_tags: true)
    @cmd_input = CW::LineEdit.new(height: 1, visible: false)
    cmdline.append @cmd_label, @cmd_input

    @cmd_input.on(CT::Event::Submitted) do
      if @prompt_active
        value = @cmd_input.value
        done = @prompt_done
        finish_prompt
        done.try &.call(value)
      end
    end
  end

  # Show a transient status message on the command line: the label zone fills
  # the whole line, the inline editor stands down.
  def show_message(text : String) : Nil
    @cmd_input.hide
    @cmd_label.content = text
    @cmd_label.width = nil
  end

  # Replace the top command hint bar.
  def set_help(text : String) : Nil
    @helpline.content = text
  end

  # Raise one center page and focus its view. Focus itself is safe against the
  # not-yet-arranged page: the render that follows re-asserts the focused
  # widget's visibility and caret against the freshly laid-out boxes.
  def show_page(name : Symbol, view : CT::Widget) : Nil
    @stack.current_index = PAGE[name]
    view.focus
  end

  # Open a command-line prompt (Mutt asks for To/Subject/headers this way): the
  # bold label shrinks to its width on the left, the inline editor fills the
  # rest of the line, and the block runs with the submitted value.
  #
  # *e* is the keypress that triggered the prompt. Accepting it marks the key
  # consumed, which is what stops `Application#route_input` from also treating
  # a command letter as the app-global quit key.
  def open_prompt(label : String, initial : String, e : CT::Event::KeyPress?, &on_done : String ->) : Nil
    @prompt_active = true
    @prompt_done = on_done
    @cmd_label.content = "{bold}#{label}{/bold}"
    @cmd_label.width = label.size
    @cmd_input.value = initial
    @cmd_input.show
    # `cmd_input` was hidden, so the enclosing HBox has not yet given it a
    # column or a width — those are assigned during the render that `focus`
    # schedules, and the end of that render re-places the caret against the
    # resolved geometry.
    @cmd_input.focus
    e.try &.accept
  end

  # Close the command-line prompt without running its block.
  def finish_prompt : Nil
    @prompt_active = false
    @prompt_done = nil
    @cmd_input.value = ""
    @cmd_input.hide
  end
end
