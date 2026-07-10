module Crysterm
  # The undo/redo stack built into `TextDocument` (the counterpart of
  # QTextDocument's internal undo, not of the general-purpose `QUndoStack`).
  #
  # Classic command list + index: `@commands[0...@index]` are undoable,
  # `@commands[@index..]` redoable. Pushing while redo entries exist drops
  # them. Commands mutate the document exclusively through its `raw_*`
  # primitives, which perform no undo bookkeeping — only the document's
  # public editing methods push commands, so undo/redo can replay safely.
  #
  # Typing coalescing (Qt semantics): a text insert merges into the previous
  # insert when it continues exactly where that one ended, with the same
  # appearance and no block separator — so a typing burst is one undo step,
  # and any jump elsewhere breaks the run naturally by failing the contiguity
  # check. Delete and Backspace runs coalesce the same way. `begin_macro`/
  # `end_macro` (Qt `beginEditBlock`) group arbitrary commands into one step.
  #
  # "Clean" tracking: `mark_clean` remembers the current index; `clean?`
  # compares against it and is unreachable (`CLEAN_INVALID`) once the clean
  # state is truncated away. `TextDocument#modified?` is `!clean?`.
  class TextUndoStack
    # Sentinel for "no reachable clean state".
    CLEAN_INVALID = Int32::MIN

    abstract class Command
      # Set once no later command may coalesce into this one (macro boundaries,
      # undo/redo). Checked by `push`.
      property? sealed = false

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
      getter text : String
      getter format : TextCharFormat

      def initialize(@pos, @text, @format)
      end

      def undo(doc : TextDocument) : Nil
        doc.raw_remove(@pos, @text.size)
      end

      def redo(doc : TextDocument) : Nil
        doc.raw_insert(@pos, @text, @format)
      end

      def try_merge(other : Command) : Bool
        return false unless other.is_a?(InsertCommand)
        return false if @text.includes?('\n') || other.text.includes?('\n')
        return false unless other.pos == @pos + @text.size
        return false unless other.format.same_appearance?(@format)
        @text += other.text
        true
      end
    end

    class RemoveCommand < Command
      getter pos : Int32
      getter fragment : TextDocumentFragment

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
          # `TextDocument#remove` returned to its caller, which must not
          # mutate under the caller's feet.
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
      # `@old_block_format`: the insertion-point block's format when a
      # multi-block insertion at a block start replaced it with the
      # fragment's head format (see `TextDocument#insert_fragment`).
      def initialize(@pos : Int32, @fragment : TextDocumentFragment,
                     @old_block_format : TextBlockFormat? = nil)
      end

      def undo(doc : TextDocument) : Nil
        if bf = @old_block_format
          # Restore before removing: `raw_remove`'s block merge keeps the
          # first block's format, so this is what the merged block ends
          # up with.
          doc.blocks[doc.block_at(@pos)[0]].block_format = bf
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

    def push(cmd : Command, doc : TextDocument) : Nil
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
      doc.refresh_undo_state
    end

    def begin_macro : Nil
      if @macro_depth == 0
        seal_last
        @macro = MacroCommand.new
      end
      @macro_depth += 1
    end

    def end_macro(doc : TextDocument) : Nil
      return if @macro_depth == 0
      @macro_depth -= 1
      return unless @macro_depth == 0
      if m = @macro
        @macro = nil
        unless m.children.empty?
          m.sealed = true
          push(m, doc)
        end
      end
    end

    def in_macro? : Bool
      @macro_depth > 0
    end

    def undo(doc : TextDocument) : Bool
      return false if in_macro? || @index == 0
      @index -= 1
      @commands[@index].undo(doc)
      seal_last
      doc.refresh_undo_state
      true
    end

    def redo(doc : TextDocument) : Bool
      return false if in_macro? || @index == @commands.size
      @commands[@index].redo(doc)
      @index += 1
      seal_last
      doc.refresh_undo_state
      true
    end

    def undo_available? : Bool
      @index > 0
    end

    def redo_available? : Bool
      @index < @commands.size
    end

    def clear : Nil
      @commands.clear
      @index = 0
      @clean_index = 0
      @macro = nil
      @macro_depth = 0
    end

    def mark_clean : Nil
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
