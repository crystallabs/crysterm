module Crysterm
  module Mixin
    # Shell-style input history: submitted texts recorded oldest-first and
    # recalled with Up/Down, with the live draft stashed on the first step
    # back so browsing never loses it.
    #
    # Includer contract: `#value : String` / `#value=(String)` (the editable
    # text; the walkers' `value=` is an external set, so the includer parks
    # its caret at the end). The includer owns the key handling — it decides
    # *when* a keypress walks (`LineEdit` on any Up/Down, `Chat::Input` only
    # with the caret on the buffer's first/last line, both gated on
    # `#history_keys?`) and calls `#history_prev`/`#history_next`; its submit
    # path calls `#record_history`.
    module InputHistory
      # Whether Up/Down walk the input history. On by default (shell-prompt
      # style); set false so the keys pass through for the host to handle,
      # e.g. to move between form fields.
      property? history_keys : Bool = true

      # Submitted texts, oldest first — the history walked by Up/Down.
      # Public so an app can pre-seed, inspect or persist it.
      getter history = [] of String

      # Cursor into `@history`; `nil` is the sentinel "on the live draft"
      # (kept lazily `nil` rather than eagerly `history.size` so a pre-seeded
      # history is reachable; walkers resolve it as
      # `@history_pos || @history.size`).
      @history_pos : Int32? = nil

      # The half-typed text stashed on the first Up, restored when Down walks
      # past the newest entry — browsing history never loses the draft.
      @history_draft = ""

      # Appends a just-submitted text to the history and resets the walk to
      # the live draft. Empty texts and an immediate repeat of the last
      # entry are skipped (shell `ignoredups`), so Up gives back meaningful
      # entries.
      private def record_history(text : String) : Nil
        @history_pos = nil
        @history_draft = ""
        return if text.empty?
        return if !@history.empty? && @history.last == text
        @history << text
      end

      # Up: recall an older entry. The first step off the live draft stashes
      # it so Down can bring it back.
      private def history_prev : Nil
        return if @history.empty?
        # `nil` (live draft) resolves to the sentinel `history.size`.
        pos = @history_pos || @history.size
        return if pos == 0
        @history_draft = value if pos == @history.size
        pos -= 1
        @history_pos = pos
        # An external set, so the includer parks the caret at the end.
        self.value = @history[pos]
      end

      # Down: recall a newer entry, or restore the stashed draft once past
      # the newest one.
      private def history_next : Nil
        pos = @history_pos || @history.size
        return if pos >= @history.size
        pos += 1
        if pos == @history.size
          @history_pos = nil
          self.value = @history_draft
        else
          @history_pos = pos
          self.value = @history[pos]
        end
      end
    end
  end
end
