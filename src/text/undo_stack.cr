module Crysterm
  # The undo/redo stack built into `TextDocument` (the counterpart of
  # QTextDocument's internal undo, not of the general-purpose `QUndoStack`).
  #
  # Classic command list + index: `@commands[0...@index]` are undoable,
  # `@commands[@index..]` redoable. Pushing while redo entries exist drops
  # them. Commands must mutate the document exclusively through its `raw_*`
  # primitives, which perform no undo bookkeeping — otherwise replay would
  # record itself.
  #
  # Typing coalescing (Qt semantics): a text insert merges into the previous
  # insert when it continues exactly where that one ended, with the same
  # appearance and no block separator, so a typing burst is one undo step and
  # any jump elsewhere breaks the run by failing the contiguity check. Delete
  # and Backspace runs coalesce the same way. `begin_macro`/`end_macro` group
  # arbitrary commands into one step.
  #
  # "Clean" tracking: `mark_clean` remembers the current index; `clean?`
  # compares against it and is unreachable (`CLEAN_INVALID`) once the clean
  # state is truncated away. `TextDocument#modified?` is `!clean?`.
  #
  # A table re-rendered to a new `TextDocument#text_width` is layout, not a
  # step, yet it moves the positions the commands hold: the stack keeps the
  # re-renderings (`#reflowed`), those between two commands on the later
  # one (`Command#reflows`), and replays each command at the width it was
  # made at — taking back the re-renderings since, undoing or redoing it,
  # then fitting the tables to the current width again.
  class TextUndoStack
    # Sentinel for "no reachable clean state".
    CLEAN_INVALID = Int32::MIN

    abstract class Command
      # Set once no later command may coalesce into this one, at macro
      # boundaries and across undo/redo.
      property? sealed = false

      # The tables' re-renderings to a new `TextDocument#text_width` made
      # after the previous command and before this one: taken back after
      # this command is undone, played again before it is redone.
      property reflows : Array(TextDocument::TableReflow)? = nil

      abstract def undo(doc : TextDocument) : Nil
      abstract def redo(doc : TextDocument) : Nil

      # Attempts to absorb `other` (called on the newest command with the
      # incoming one). Returns true when absorbed.
      def try_merge(other : Command) : Bool
        false
      end
    end

    class InsertCommand < Command
      getter pos : Int32
      getter format : TextCharFormat

      # Coalescing accumulator: a typing burst appends into `@io`, amortized
      # O(1) per key, where rebuilding an accumulated String would be O(k^2)
      # over a k-char run. `@size` tracks the codepoint length, which
      # contiguity and undo need and `IO::Memory` cannot give (it counts
      # bytes); `@has_newline` caches the block-separator guard.
      protected getter size : Int32
      protected getter? has_newline : Bool

      def initialize(@pos, text : String, @format)
        @io = IO::Memory.new
        @io << text
        @size = text.size
        @has_newline = text.includes?('\n')
      end

      # The accumulated inserted text, materialized on demand — the redo path,
      # not the hot typing path. `IO::Memory#to_s` leaves the buffer writable,
      # so later merges still append.
      def text : String
        @io.to_s
      end

      def undo(doc : TextDocument) : Nil
        doc.raw_remove(@pos, @size)
      end

      def redo(doc : TextDocument) : Nil
        doc.raw_insert(@pos, text, @format)
      end

      def try_merge(other : Command) : Bool
        return false unless other.is_a?(InsertCommand)
        return false if @has_newline || other.has_newline?
        return false unless other.pos == @pos + @size
        return false unless other.format.same_appearance?(@format)
        @io << other.text
        @size += other.size
        true
      end
    end

    class RemoveCommand < Command
      getter pos : Int32
      # Protected: this is the undo record itself — an outside mutation of it
      # would rewrite what undo restores (`TextDocument#remove` already hands
      # its caller a copy for the same reason).
      protected getter fragment : TextDocumentFragment

      def initialize(@pos, @fragment)
      end

      def undo(doc : TextDocument) : Nil
        doc.raw_insert_fragment(@pos, @fragment)
      end

      def redo(doc : TextDocument) : Nil
        doc.raw_remove(@pos, @fragment.size)
      end

      def try_merge(other : Command) : Bool
        return false unless other.is_a?(RemoveCommand)
        # Only single-block runs coalesce; removals spanning a separator stay
        # their own steps (Qt seals at block boundaries too).
        return false unless @fragment.blocks.size == 1 && other.fragment.blocks.size == 1
        if other.pos == @pos
          # Forward-delete run: subsequent removal happens at the same
          # position. Merge into a clone — `@fragment` is the very object
          # handed back to the code that requested the removal, and must not
          # mutate under it.
          merged = @fragment.blocks[0].clone
          merged.merge_with(other.fragment.blocks[0])
          @fragment = TextDocumentFragment.new([merged])
        elsif other.pos + other.fragment.size == @pos
          # Backspace run: subsequent removal ends where this one starts.
          merged = other.fragment.blocks[0].clone
          merged.merge_with(@fragment.blocks[0])
          @fragment = TextDocumentFragment.new([merged])
          @pos = other.pos
        else
          return false
        end
        true
      end
    end

    # A formatted-fragment insertion (rich paste). Never coalesces; commands
    # never mutate their fragment, so several commands may share one (e.g.
    # the same clipboard fragment pasted twice).
    class InsertFragmentCommand < Command
      # `@old_block_format`: the insertion-point block's format, when a
      # multi-block insertion at a block start replaced it with the fragment's
      # head format.
      def initialize(@pos : Int32, @fragment : TextDocumentFragment,
                     @old_block_format : TextBlockFormat? = nil)
      end

      def undo(doc : TextDocument) : Nil
        if bf = @old_block_format
          # Restore before removing: `raw_remove`'s block merge keeps the
          # first block's format, so this is what the merged block ends
          # up with.
          doc.blocks[doc.block_at(@pos).index].block_format = bf
        end
        doc.raw_remove(@pos, @fragment.size)
      end

      def redo(doc : TextDocument) : Nil
        doc.raw_insert_fragment(@pos, @fragment)
      end
    end

    class CharFormatCommand < Command
      def initialize(
        @from : Int32,
        @to : Int32,
        @format : TextCharFormat,
        @merge : Bool,
        # Pre-change appearance, as absolute-position runs.
        @old_runs : Array({Int32, Int32, TextCharFormat}),
      )
      end

      def undo(doc : TextDocument) : Nil
        @old_runs.each do |(from, to, format)|
          doc.raw_apply_char_format(from, to, format, merge: false)
        end
      end

      def redo(doc : TextDocument) : Nil
        doc.raw_apply_char_format(@from, @to, @format, @merge)
      end
    end

    class BlockFormatCommand < Command
      def initialize(
        @from : Int32,
        @to : Int32,
        @format : TextBlockFormat,
        @merge : Bool,
        # Pre-change formats keyed by each block's start position.
        @old_formats : Array({Int32, TextBlockFormat}),
      )
      end

      def undo(doc : TextDocument) : Nil
        @old_formats.each do |(pos, format)|
          doc.raw_set_block_format_at(pos, format)
        end
      end

      def redo(doc : TextDocument) : Nil
        doc.raw_apply_block_format(@from, @to, @format, @merge)
      end
    end

    # An edit block (Qt `beginEditBlock`): children undo in reverse as one step.
    class MacroCommand < Command
      getter children = [] of Command

      def undo(doc : TextDocument) : Nil
        @children.reverse_each &.undo(doc)
      end

      def redo(doc : TextDocument) : Nil
        @children.each &.redo(doc)
      end
    end

    @commands = [] of Command
    @index = 0
    @clean_index = 0
    @macro : MacroCommand?
    @macro_depth = 0
    # The re-renderings since the stack last moved (a push, an undo, a
    # redo): what stands between the current text and the one the next
    # command to undo or redo expects.
    @reflows = [] of TextDocument::TableReflow

    # The owning document — the stack is `TextDocument`-internal (one stack
    # per document, built by it), so commands always replay against their own
    # document; a per-call document parameter allowed
    # `docA.undo_stack.undo(docB)` to silently corrupt B.
    private getter document : TextDocument

    def initialize(@document : TextDocument)
    end

    def push(cmd : Command) : Nil
      # The re-renderings since the last move now precede this command.
      unless @reflows.empty?
        target = @macro || cmd
        target.reflows = (target.reflows || [] of TextDocument::TableReflow).concat(@reflows)
        @reflows.clear
      end
      if m = @macro
        unless (last = m.children.last?) && !last.sealed? && last.try_merge(cmd)
          m.children << cmd
        end
        return
      end
      if @index < @commands.size
        @commands.pop(@commands.size - @index)
        @clean_index = CLEAN_INVALID if @clean_index > @index
      end
      unless (last = @commands.last?) && !last.sealed? && last.try_merge(cmd)
        @commands << cmd
        @index += 1
      end
      document.refresh_undo_state
    end

    def begin_macro : Nil
      if @macro_depth == 0
        seal_last
        @macro = MacroCommand.new
      end
      @macro_depth += 1
    end

    def end_macro : Nil
      return if @macro_depth == 0
      @macro_depth -= 1
      return unless @macro_depth == 0
      if m = @macro
        @macro = nil
        unless m.children.empty?
          m.sealed = true
          push(m)
        end
      end
    end

    def in_macro? : Bool
      @macro_depth > 0
    end

    def undo : Bool
      return false if in_macro? || @index == 0
      return false unless take_back_reflows
      @index -= 1
      cmd = @commands[@index]
      cmd.undo(document)
      cmd.reflows.try { |r| drop_history unless document.replay_reflows(r, backward: true) }
      refit
      true
    end

    def redo : Bool
      return false if in_macro? || @index == @commands.size
      return false unless take_back_reflows
      cmd = @commands[@index]
      if (r = cmd.reflows) && !document.replay_reflows(r, backward: false)
        drop_history
        refit
        return false
      end
      cmd.redo(document)
      @index += 1
      refit
      true
    end

    # Records *reflows*, tables just re-rendered to a new
    # `TextDocument#text_width` (see the class docs); nothing coalesces
    # across them. With no history there is nothing to replay.
    #
    # A table re-rendered again is kept as one re-rendering, from its
    # rendering at the last move to the latest, and dropped when that is
    # where it started (a resize back and forth), so a drag through many
    # widths holds one copy per table. The tables are apart and each
    # re-rendering keeps the block count, so they need no order among them.
    def reflowed(reflows : Array(TextDocument::TableReflow)) : Nil
      return if reflows.empty? || !(undo_available? || redo_available?)
      seal_last
      reflows.each do |r|
        if i = @reflows.index { |q| q.first == r.first && q.new.size == r.old.size }
          q = @reflows[i]
          if q.old.map(&.text) == r.new.map(&.text)
            @reflows.delete_at(i)
          else
            @reflows[i] = TextDocument::TableReflow.new(q.first, q.old, r.new)
          end
        else
          @reflows << r
        end
      end
    end

    # Forgets every step, keeping `#clean?` false when it was — the last
    # resort when the text no longer matches what the commands expect.
    def drop_history : Nil
      dirty = !clean?
      clear
      mark_dirty if dirty
      document.refresh_undo_state
    end

    # Takes the re-renderings since the last move back, so the text is the
    # one the next command to undo or redo expects; false, the history
    # dropped, when a table is not as they left it.
    private def take_back_reflows : Bool
      ok = document.replay_reflows(@reflows, backward: true)
      @reflows.clear
      unless ok
        drop_history
        refit
      end
      ok
    end

    # After a move: the tables fitted to the current width again, the
    # re-renderings kept for the next move.
    private def refit : Nil
      seal_last
      reflowed(document.fit_tables(document.text_width))
      document.refresh_undo_state
    end

    def undo_available? : Bool
      @index > 0
    end

    def redo_available? : Bool
      @index < @commands.size
    end

    def clear : Nil
      @commands.clear
      @reflows.clear
      @index = 0
      @clean_index = 0
      @macro = nil
      @macro_depth = 0
    end

    def mark_clean : Nil
      seal_last
      @clean_index = @index
    end

    def mark_dirty : Nil
      @clean_index = CLEAN_INVALID
    end

    def clean? : Bool
      @clean_index == @index
    end

    # Prevents further coalescing into the newest *reachable* command,
    # `@commands[@index - 1]` — the command `push` would merge into once the
    # redo tail is truncated. Sealing `@commands.last` would miss it whenever
    # a redo tail exists (typing after undo/redo would coalesce across the
    # boundary into a pre-undo command).
    def seal_last : Nil
      return if @index == 0
      @commands[@index - 1].sealed = true
    end
  end
end
