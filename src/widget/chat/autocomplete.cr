require "../../chat/completion"
require "../../control/completer"
require "../../mixin/popup_controller"
require "../../overlay/dismiss_session"
require "../plaintextedit"

module Crysterm
  class Widget
    module Chat
      # The chat input's trigger-key completion menu: typing `/`, `@`, `!` or
      # `#` (whatever the `Registry` maps) pops a filterable suggestion list
      # over the input, Claude-CLI style. Slash commands and `@`-file mentions
      # share this one menu — each trigger just supplies its own candidates.
      #
      # Like `Crysterm::Completer`, this is not a widget: it attaches to a
      # `Widget::PlainTextEdit` (typically a `Chat::Input`) and watches its
      # keystrokes — the two share their controller plumbing via
      # `Mixin::PopupController`. Unlike `Completer`, which matches the box's
      # whole value, this completes the *token under the caret*: the run of
      # non-whitespace characters back from the caret, whose first character
      # must be a registered trigger — at the very start of the buffer for
      # `/`-style triggers, at any word start for `@`-style ones
      # (`Completion::Source#anywhere?`).
      #
      # ```
      # input = Widget::Chat::Input.new parent: window, bottom: 0, width: "100%"
      # reg = ::Crysterm::Chat::Completion::Registry.new
      # reg.register '/', commands
      # reg.register('@') { |q| files.matching q }
      # ac = Widget::Chat::Autocomplete.new reg
      # ac.attach input
      # ```
      #
      # ### Keys (while the menu is open)
      #
      # * `Down`/`Up` move the highlight (consumed — the input's own
      #   history/caret motion stands down while the menu owns them);
      # * `Enter`/`Tab` accept the highlighted candidate: the whole token is
      #   replaced with trigger + name + a space (`Shift+Enter` passes
      #   through, so an explicit newline still works mid-completion);
      # * `Esc` dismisses. Typing on reopens it; caret motion alone does not
      #   (the same text-change dedup contract as `Completer`).
      #
      # A click on a row accepts it; a press outside menu + input dismisses.
      # The input keeps focus (and keeps filtering) the whole time — the menu
      # never takes a modal grab.
      #
      # Accepting emits no event of its own — the input's `TextChanged` fires
      # from the edit — but `#accept_handler` observes the chosen `Item` (e.g. to
      # switch the input into bash mode on a `!` completion).
      class Autocomplete
        # The trigger→candidates table consulted on every keystroke.
        property registry : ::Crysterm::Chat::Completion::Registry

        # The suggestion list. Inherits the drop-down behavior contract from
        # `Completer::Popup` (single-click commit, hover highlight, wheel
        # scrolls under a stationary pointer, never steals focus) and reroutes
        # commit/cancel to the owning `Autocomplete`. Rows are tag-styled
        # (name column + dimmed description), hence `parse_tags`.
        class Popup < ::Crysterm::Completer::Popup
          property autocomplete : Autocomplete?

          def activate_current
            autocomplete.try &.commit_index(current_index)
          end

          def cancel_current
            autocomplete.try &.close
          end
        end

        # The token being completed: *trigger* + the query typed so far,
        # starting at codepoint *start* of the buffer.
        private record Context, trigger : Char, start : Int32, query : String

        include ::Crysterm::Mixin::PopupController(
          Widget::PlainTextEdit, Popup, ::Crysterm::Chat::Completion::Item,
        )

        @context : Context?
        @accept_handler : Proc(::Crysterm::Chat::Completion::Item, Nil)?

        def initialize(@registry = ::Crysterm::Chat::Completion::Registry.new)
        end

        # Subscribes *block* to completion acceptance; it receives the chosen
        # `Item` after the token has been replaced in the buffer.
        @[Deprecated("Renamed to `#accept_handler` — a single overwritable slot, not an `on_*` multicast subscription.")]
        def on_accept(&block : ::Crysterm::Chat::Completion::Item ->) : Nil
          accept_handler(&block)
        end

        def accept_handler(&block : ::Crysterm::Chat::Completion::Item ->) : Nil
          @accept_handler = block
        end

        private def detach_reset : Nil
          @context = nil
        end

        # Accepts the candidate at *index* in the current matches: replaces
        # the whole caret token (trigger through the next whitespace) with
        # trigger + name + a space, as one undo step, parking the caret after
        # the space. Public so the popup can commit the row the user clicked.
        def commit_index(index : Int32) : Nil
          item = @matches[index]?
          if item && (w = @widget) && (ctx = @context)
            fin = w.cursor_pos
            while fin < w.buf_size && !boundary?(w.buf_char(fin))
              fin += 1
            end
            w.buf_edit_group do
              w.buf_delete ctx.start, fin
              w.cursor_pos = ctx.start
              # Emits `TextChanged`, repaints and re-places the cursor — the
              # same path typing the characters would take.
              w.insert_text "#{ctx.trigger}#{item.name} "
            end
          end
          close
          # Retyping over the committed text is a real edit that should
          # reopen, so don't let `#close`'s recorded value suppress it.
          @last_filter_value = nil
          item.try { |it| @accept_handler.try &.call it }
        end

        # The token under the caret, when its first character is a registered
        # trigger in a position that trigger fires at.
        private def context_at_caret : Context?
          w = @widget || return
          pos = w.cursor_pos
          start = pos
          while start > 0 && !boundary?(w.buf_char(start - 1))
            start -= 1
          end
          return if start >= pos
          trigger = w.buf_char start
          src = @registry.source?(trigger) || return
          return if !src.anywhere? && start != 0
          Context.new trigger, start, w.buf_slice(start + 1, pos)
        end

        private def boundary?(ch : Char) : Bool
          ch == ' ' || ch == '\n' || ch == '\t'
        end

        # The per-keystroke filter pass: recompute the caret token and matches,
        # then open/refresh/close the menu accordingly. The menu opens purely
        # from typing a trigger, never from a bare arrow key (those belong to
        # the chat input's history/caret).
        private def filter_pass(_widget : Widget::PlainTextEdit) : Nil
          ctx = context_at_caret
          unless ctx
            close
            return
          end
          @matches = @registry.complete ctx.trigger, ctx.query
          if @matches.empty?
            close
            return
          end
          @context = ctx
          val = @widget.try &.value
          if @open
            refresh
          elsif val != @last_filter_value
            open_popup
          end
          @last_filter_value = val if @open
        end

        private def handle_intercept(e : ::Crysterm::Event::KeyPress) : Nil
          return unless @open
          case e.key
          when Tput::Key::Down   then move_popup &.cursor_down; consume e
          when Tput::Key::Up     then move_popup &.cursor_up; consume e
          when Tput::Key::Tab    then accept_current; consume e
          when Tput::Key::Escape then close; consume e
          when Tput::Key::Enter
            # Shift+Enter stays the input's explicit-newline gesture even with
            # the menu open; the newline then closes it (a boundary ends the
            # token).
            unless e.shift?
              accept_current
              consume e
            end
          end
        end

        # The menu rows for the current matches: the trigger-prefixed name,
        # left-justified into a shared column, then the dimmed description.
        # Names/descriptions are tag-escaped so a literal brace can't inject
        # styling.
        private def popup_rows : Array(String)
          trigger = @context.try(&.trigger.to_s) || ""
          name_w = @matches.max_of(&.name.size) + trigger.size
          @matches.map do |item|
            label = Widget.escape_tags "#{trigger}#{item.name}"
            if item.description.empty?
              label
            else
              "#{label.ljust(name_w)}  {gray-fg}#{Widget.escape_tags item.description}{/gray-fg}"
            end
          end
        end

        private def build_popup(widget : Widget::PlainTextEdit) : Popup
          pop = Popup.new(
            window: widget.window,
            top: 0, left: 0,
            width: 16, height: 3,
            style: Style.new(border: true),
            overflow: ::Crysterm::Overflow::MoveWidget,
            parse_tags: true,
          )
          pop.autocomplete = self
          pop
        end
      end
    end
  end
end
