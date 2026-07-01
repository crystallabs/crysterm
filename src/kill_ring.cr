module Crysterm
  # An emacs/readline-style kill ring: the shared text register that the
  # readline editing keys push deleted text into (`Ctrl-W` / `Ctrl-U` / `Ctrl-K`
  # / `Alt-D`) and `Ctrl-Y` yanks back. See `Mixin::TextEditing`.
  #
  # Consecutive kills accumulate into one entry (so `Ctrl-K Ctrl-K` yanks both
  # lines, and a backward kill prepends) until a non-kill action calls
  # `#interrupt`, matching emacs behavior. Older entries are retained up to
  # `#max` for a future yank-pop.
  #
  # A process-wide `default` instance is shared by every text-editable widget,
  # so text killed in one field can be yanked into another. An application may
  # swap `KillRing.default`, or give a single widget its own ring via
  # `Mixin::TextEditing#kill_ring=`.
  class KillRing
    # Shared default ring used by all text inputs unless overridden per widget.
    class_property default : KillRing { KillRing.new }

    # Kill entries, oldest first; the last is what `#yank` returns.
    getter entries = [] of String

    # Maximum number of entries kept (older ones are dropped).
    property max : Int32

    # Whether the previous editing action was a kill, so the next consecutive
    # kill merges into the same entry rather than starting a new one.
    @last_was_kill = false

    def initialize(@max : Int32 = 60)
    end

    # Records *text* as a kill. A backward kill (*prepend* true — `Ctrl-W` /
    # `Ctrl-U`) joins the front of the current entry; a forward kill (*prepend*
    # false — `Ctrl-K` / `Alt-D`) joins the back. Consecutive kills merge; an
    # intervening `#interrupt` starts a fresh entry. Empty text is ignored.
    def kill(text : String, prepend : Bool = false) : Nil
      return if text.empty?
      if @last_was_kill && (last = @entries.last?)
        @entries[-1] = prepend ? text + last : last + text
      else
        @entries << text
        while @entries.size > @max
          @entries.shift
        end
      end
      @last_was_kill = true
    end

    # The most-recently killed text (what `Ctrl-Y` yanks), or `nil` when empty.
    def yank : String?
      @entries.last?
    end

    # Marks that a non-kill action happened, so the next kill starts a new entry.
    def interrupt : Nil
      @last_was_kill = false
    end

    # Drops all entries (and resets the accumulation flag).
    def clear : Nil
      @entries.clear
      @last_was_kill = false
    end
  end
end
