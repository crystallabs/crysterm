require "./text_editing/buffer"
require "./text_editing/flat_buffer"
require "./text_editing/document_buffer"

module Crysterm
  module Mixin
    # The "editable text buffer" concern: buffer, caret, wrapping, selection and
    # key handling, shared without inheritance.
    #
    # Qt's `QLineEdit` is a `QWidget`, *not* a `QAbstractScrollArea` (which is
    # `QPlainTextEdit`'s base). Crysterm mirrors that by sharing the editing
    # behavior as a module, so a widget can get it without becoming a scroll area.
    # The viewport machinery this calls (`@child_base`, `wrapped_lines`,
    # `ensure_visible`, `scroll`, `process_content`, …) lives on the base
    # `Widget`, so a plain `Box`/`Input` includer has it available.
    #
    # The including widget:
    #   * also includes a `Buffer` adapter — `FlatBuffer` (one `String`) or a
    #     `TextDocument`-backed one — supplying the `buf_*` methods and the
    #     `value`/`value=` widget API this module's shared logic calls;
    #   * calls `setup_text_editing` from `initialize` (after `super`) to wire the
    #     cursor-tracking and read handlers.
    module TextEditing
      include Buffer

      macro included
        @_reading = false
        @input_on_focus = false
        @_skip_rewind = false
      end

      # Whether finishing a read (Enter/Escape, or blur) should `rewind_focus`
      # back to the previously-focused widget. True suits one-shot inputs (a
      # prompt returning focus to its opener). A persistent form field that
      # wants to control focus itself (e.g. advance to the next field) sets
      # this false so finishing leaves focus put.
      property? rewind_on_done : Bool = true

      # The buffer's text — Qt's `QLineEdit#text` / `QPlainTextEdit#toPlainText`,
      # and the name to reach for on a text widget.
      #
      # A synonym for `#value`, which stays the *generic* widget-value name every
      # value widget answers to.
      def text : String
        value
      end

      # :ditto:
      def text=(text : String)
        self.value = text
      end

      # Whether anyone is listening for `Event::TextChanged` (or its
      # user-edit sibling `Event::TextEdited`, emitted from the same sites),
      # used to skip building the events' payload when nobody would read it.
      #
      # The payload is `#buf_text` — for a document-backed buffer that is a full
      # `String` rebuild of the document on every content-changing keystroke, so
      # the guard is worth having. Call sites must keep `update!` and
      # `_update_cursor` *outside* the guard: rendering does not depend on
      # anyone observing the event.
      #
      # Caveat: `has_handlers?` inspects only the concrete handler lists, not
      # the `AnyEvent` list that `emit` also consults, so a listener
      # registered *purely* via `AnyEvent` stops seeing these at guarded
      # sites. That is the same trade-off already accepted for `Event::Key` at
      # `Window#emit_key_transition` (src/window_interaction.cr).
      private def text_change_observed? : Bool
        has_handlers?(Crysterm::Event::TextChanged) ||
          has_handlers?(Crysterm::Event::TextEdited)
      end

      # Last-notified caret/selection state, backing `#emit_caret_events`.
      @_last_caret_pos = 0
      @_last_selection : Range(Int32, Int32)? = nil

      # Emits `Event::CursorPositionChanged`/`Event::SelectionChanged` when
      # the caret or selection differs from the last check — the shared tail
      # of every user-facing interaction (keystroke, mouse, paste,
      # programmatic move), so call sites don't compare state themselves.
      # Change-guarded here rather than at each write to `@cursor_pos`, whose
      # transient intermediate values (e.g. a delete's collapse-then-insert)
      # are not observable positions.
      private def emit_caret_events : Nil
        if @cursor_pos != @_last_caret_pos
          @_last_caret_pos = @cursor_pos
          emit Crysterm::Event::CursorPositionChanged, @cursor_pos
        end
        sel = selection_range
        if sel != @_last_selection
          @_last_selection = sel
          emit Crysterm::Event::SelectionChanged
        end
      end

      # Inserts *str* at the cursor, replacing the selection if there is one —
      # exactly what typing the characters would do (Qt's `QLineEdit#insert`).
      #
      # Named `insert_text`, not `insert`: `Widget#insert` already means "insert a
      # child widget" (`Mixin::Children#insert`).
      def insert_text(str : String) : Nil
        # Nothing to insert and nothing to replace ⇒ no change, so no event and
        # no repaint (inserting `""` over a selection still deletes it).
        return if str.empty? && !selection?
        # Capped like every other interactive insert path (typing, Ctrl-V,
        # Ctrl-Y): Qt's `QLineEdit#insert` honors maxLength, and the bracketed
        # `Event::Paste` handler routes through here.
        had_selection = selection?
        before_size = buf_size
        insert_capped str
        # A full field with nothing selected inserted nothing: no event, no
        # repaint (with a selection the text always changed — it was deleted).
        return if !had_selection && buf_size == before_size
        ensure_cursor_visible
        ensure_cursor_visible_x
        if text_change_observed?
          after = buf_text
          emit Crysterm::Event::TextChanged, after
          # Paste and `#insert_text` count as user edits (Qt's `textEdited`
          # scope), unlike `value=`.
          emit Crysterm::Event::TextEdited, after
        end
        emit_caret_events
        update!
        _update_cursor
      end

      # Insertion-point position, as a codepoint index into the buffer
      # (`0..buf_size`). Setting `value=` externally moves it to the end.
      # Movement and deletion step over whole grapheme clusters under
      # `full_unicode?`, a single codepoint otherwise.
      @cursor_pos = 0

      def cursor_position : Int32
        @cursor_pos
      end

      # Sets the cursor position, clamped to the valid buffer range
      # (`0..buf_size`). Emits `Event::CursorPositionChanged` when it moved —
      # programmatic moves notify like interactive ones (Qt semantics).
      def cursor_position=(value : Int32) : Int32
        @cursor_pos = value.clamp(0, buf_size)
        emit_caret_events
        @cursor_pos
      end

      # Alias for `#cursor_position`. 327 call sites across the codebase use
      # this spelling; new code should prefer `#cursor_position`.
      def cursor_pos : Int32
        cursor_position
      end

      # Alias for `#cursor_position=`.
      def cursor_pos=(value : Int32) : Int32
        self.cursor_position = value
      end

      # The fixed end of an in-progress mouse selection (a codepoint index into the
      # buffer), or `nil` when nothing is selected. `#cursor_pos` is the other,
      # moving end. Any keyboard interaction or external `value=` drops it: there
      # is no keyboard-extend (Shift+arrow) support yet, so a plain keystroke
      # always means "the selection is no longer live".
      property selection_anchor : Int32? = nil

      # The selected range as `[lo, hi)` codepoint indices into the buffer, or
      # `nil` when nothing is selected (no anchor, or anchor and cursor coincide
      # — a plain click with no drag).
      def selection_range : Range(Int32, Int32)?
        return unless anchor = @selection_anchor
        lo, hi = anchor < cursor_pos ? {anchor, cursor_pos} : {cursor_pos, anchor}
        return if lo == hi
        lo...hi
      end

      # Whether anything is selected (Qt's `hasSelectedText`).
      def selection? : Bool
        !!selection_range
      end

      # The currently-selected substring of the buffer, or `""` when nothing is
      # selected.
      def selected_text : String
        (r = selection_range) ? buf_slice(r.begin, r.end) : ""
      end

      # Selects the whole buffer, parking the cursor at the end (Qt's
      # `selectAll`).
      def select_all : Nil
        @selection_anchor = 0
        @cursor_pos = buf_size
        @goal_col = nil
        emit_caret_events
        update!
      end

      # Drops the in-progress/completed mouse selection without moving the
      # cursor.
      def clear_selection : Nil
        @selection_anchor = nil
      end

      # While this widget is reading, Up/Down/Ctrl-U/Ctrl-D/PageUp/PageDown/Home/End
      # are editing keys routed to `#_listener`, so the `Mixin::Interactive` scroll
      # handler must stand down to avoid double-handling them (scrolling the
      # viewport AND moving the caret/killing text). Outside reading, viewer
      # scrolling is fine.
      def viewer_scroll_keys? : Bool
        !@_reading
      end

      # Max characters the user may type, `nil` for unlimited (Qt's
      # `QLineEdit#maxLength`). Enforced only for interactive input; `value=`
      # set programmatically is not truncated.
      property max_length : Int32? = nil

      # When true, interactive editing is disabled but the cursor can still move
      # and content can be scrolled/inspected (Qt's read-only mode). `value=`
      # still works programmatically.
      property? read_only : Bool = false

      # Desired column for vertical (Up/Down) movement, as a codepoint offset
      # into the target real line. Set on the first Up/Down so that walking
      # across short lines and back preserves the original column, and cleared
      # by any other cursor movement or edit. `nil` means "no memory yet".
      @goal_col : Int32? = nil

      # Transient carrier for the `{real_line, col}` a keystroke's
      # `ensure_cursor_visible`/`_update_cursor` pair share, so `cursor_rowcol`
      # runs once per movement rather than twice. MUST be non-nil only for the
      # duration of that paired call, so no stale mapping leaks across keystrokes.
      @_pending_rowcol : Tuple(Int32, Int32)? = nil

      # Read-completion callbacks and the active key listener — internal read
      # machinery, no public accessors.
      @_done : Proc(String?, Nil)?
      @__done : Proc(String?, Nil)?
      @__listener : Proc(Crysterm::Event::KeyPress, Nil)?

      @ev_read_input_on_focus : ::EventHandler::Subscription?
      @ev_enter : ::EventHandler::Subscription?
      @ev_reading : ::EventHandler::Subscription?
      @ev_done_blur : ::EventHandler::Subscription?

      # Wires the cursor-following handlers and the optional Enter-to-read
      # accelerator. Call from `initialize` after `super`. `install_enter` installs
      # the Enter-to-read accelerator only when the caller explicitly asked for
      # `keys:`.
      private def setup_text_editing(input_on_focus = false, install_enter = false) : Nil
        on(Crysterm::Event::Resize) do
          _update_cursor
        end
        on(Crysterm::Event::Move) do
          _update_cursor
        end

        self.input_on_focus = input_on_focus

        if !@input_on_focus && install_enter
          @ev_enter = on(Crysterm::Event::KeyPress) do |e|
            next if @_reading
            if e.key.try &.==(Tput::Key::Enter)
              read_input
            end
          end
        end

        # A paste (bracketed paste, routed by the window to the focused widget)
        # inserts at the cursor exactly as typing it would. A read-only widget
        # leaves the event unaccepted, so it still propagates/falls back.
        on(Crysterm::Event::Paste) do |e|
          next if read_only?
          insert_text sanitize_paste(e.content)
          e.accept
        end

        _setup_text_mouse
      end

      # Adapts pasted text to what this widget can hold before it is inserted.
      # The default keeps it verbatim (multiline editors take newlines as-is);
      # single-line widgets override (`Widget::LineEdit` flattens newlines).
      private def sanitize_paste(text : String) : String
        text
      end

      # Installs the click-to-position / drag-to-select mouse handler.
      #
      # A press moves the cursor to the clicked position and drops an anchor there.
      # It deliberately does NOT `#accept` the event: `Window#dispatch_mouse` still
      # needs to run its own default click-to-focus and emit `Event::Click`. This
      # handler owns only the cursor/selection side effect, not the click itself.
      #
      # A subsequent `Event::Mouse` reporting motion with a button still held
      # (`ev.button` is populated on `Move`, not just `Down`/`Up`) extends the
      # selection and repaints so the highlight tracks the drag live. Taking the
      # anchor lazily (`@selection_anchor ||=`) tolerates a drag whose initial
      # press this widget didn't see.
      private def _setup_text_mouse : Nil
        on(Crysterm::Event::Mouse) do |e|
          if e.action.down?
            @goal_col = nil
            pos = position_at(e.x, e.y)
            clicks = window?.try(&.click_count) || 1
            if clicks >= 3
              # Triple-click selects the whole logical line. An empty span must
              # leave the anchor nil, never seed it at the caret — see the
              # single-click branch below.
              @cursor_pos = pos
              a = line_start_pos
              b = line_end_pos
              @selection_anchor = (a == b ? nil : a)
              @cursor_pos = b
            elsif clicks == 2
              # Double-click selects the word under the pointer. On non-word text
              # `word_bounds_at` returns an empty `{pos, pos}`, which must leave
              # the anchor nil — see the single-click branch below.
              a, b = word_bounds_at(pos)
              @selection_anchor = (a == b ? nil : a)
              @cursor_pos = b
            else
              @cursor_pos = pos
              # A plain click positions the caret with NO selection. An anchor
              # equal to the caret is a landmine: it reports as "no selection"
              # only while the caret sits on it, and the next cursor-moving edit
              # leaves it behind as a bogus range whose end can exceed the
              # now-shorter value, crashing `#delete_selection` with an IndexError.
              # The drag path seeds the anchor lazily on first motion instead.
              @selection_anchor = nil
            end
            # Capture the mouse so a drag that leaves our bounds keeps extending
            # the selection (released on button-up in `Window#dispatch_mouse`).
            window?.try &.capture_mouse(self)
            # Reflect the reposition/selection ourselves rather than relying on
            # `dispatch_mouse`'s click-to-focus render, which is skipped when
            # `focus_on_click?` is off. `paint` repositions the terminal caret via
            # `_update_cursor` too.
            emit_caret_events
            update!
          elsif e.action.move? && !e.button.none? && focused?
            # Extend the selection to the pointer. If the pointer is past the
            # vertical edge, scroll first so the drag can select off-window
            # content (`scrolled` also forces a repaint even if the mapped
            # position didn't change).
            scrolled = autoscroll_for_drag e.y
            pos = position_at(e.x, e.y)
            next if pos == @cursor_pos && @selection_anchor && !scrolled
            @goal_col = nil
            @selection_anchor ||= @cursor_pos
            @cursor_pos = pos
            emit_caret_events
            update!
            e.accept
          end
        end
      end

      # The maximum visible content-row index for the viewport described by *lpos*.
      # Each caller applies its own `.clamp` tail, whose first operand differs.
      private def max_content_row(lpos) : Int32
        (lpos.yl - lpos.yi) - ivertical - 1
      end

      # During a drag-select, scrolls one row when the pointer is past the top or
      # bottom of the visible content, so the selection can extend beyond the
      # viewport. Returns whether it scrolled. No-op for a non-scrollable widget.
      # Uses the same row geometry as `#position_at`.
      private def autoscroll_for_drag(y : Int32) : Bool
        return false unless @scrollable
        lpos = @lpos || coords
        return false unless lpos
        max_line = max_content_row(lpos)
        raw = y - lpos.yi - itop
        before = @child_base
        if raw < 0
          scroll(-1)
        elsif raw > max_line
          scroll(1)
        end
        @child_base != before
      end

      # A text editor's "scrollable right now" is a real content-vs-height overflow
      # test, not the `@shrink_to_fit` always-scrollable short-circuit inherited
      # from `Input`, which would show an `AsNeeded` vertical bar even when the
      # content fits.
      def overflows_y?
        content_overflows_height?
      end

      # Reserves one extra right-edge column beyond the scroll bar's so the caret
      # has somewhere to sit at the end of a full-width line.
      def content_margin_x : Int32
        super + 1
      end
    end
  end
end

require "./text_editing/geometry"
require "./text_editing/input"
