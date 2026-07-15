module Crysterm
  # An editing position (with optional selection) in a `TextDocument`, and
  # the API every document mutation routes through (Qt `QTextCursor`).
  #
  # A cursor is `position` plus `anchor`; they differ while a selection
  # exists. Cursors register with their document and are adjusted on every
  # edit — including edits made through *other* cursors — so any number can
  # stay live on one document (Qt's invariant; registration is weak, so
  # dropping a cursor needs no explicit cleanup).
  #
  # Document-level cursors know blocks, not visual lines: `StartOfLine` ==
  # `StartOfBlock` and `Up`/`Down` move by block preserving the block-local
  # column. Wrapped-line motion and sticky visual columns belong to the
  # viewing widget.
  class TextCursor
    enum MoveMode
      Move
      KeepAnchor
    end

    # Movement operations. Qt's duplicate names — `Left`/`PreviousCharacter`
    # and friends — are distinct members that behave identically, as in Qt.
    enum MoveOperation
      NoMove
      Start
      End
      Left
      PreviousCharacter
      Right
      NextCharacter
      WordLeft
      PreviousWord
      WordRight
      NextWord
      StartOfLine
      StartOfBlock
      EndOfLine
      EndOfBlock
      StartOfWord
      EndOfWord
      PreviousBlock
      NextBlock
      Up
      Down
    end

    enum SelectionType
      WordUnderCursor
      LineUnderCursor
      BlockUnderCursor
      Document
    end

    getter document : TextDocument
    getter position : Int32 = 0
    getter anchor : Int32 = 0

    # Typing format set by `set_char_format`/`merge_char_format` without a
    # selection (Qt: the cursor's current character format). Consumed by the
    # next `insert_text`; movement clears it.
    @pending_format : TextCharFormat?

    def initialize(@document : TextDocument, position : Int32 = 0)
      @position = @anchor = position.clamp(0, @document.size)
      @document.register_cursor(self)
    end

    def set_position(pos : Int32, mode : MoveMode = :move) : Nil
      @pending_format = nil
      @position = pos.clamp(0, @document.size)
      @anchor = @position if mode.move?
    end

    # Performs `op` `n` times (Qt `movePosition`). Returns true when all `n`
    # movements were possible; the cursor still moves as far as it can.
    def move_position(op : MoveOperation, mode : MoveMode = :move, n : Int32 = 1) : Bool
      target = @position
      moved_all = true
      n.times do
        step = one_move(target, op)
        if step.nil?
          moved_all = false
          break
        end
        target = step
      end
      set_position(target, mode)
      moved_all
    end

    # === Selection ===

    def selection? : Bool
      @position != @anchor
    end

    def selection_start : Int32
      Math.min(@position, @anchor)
    end

    def selection_end : Int32
      Math.max(@position, @anchor)
    end

    def clear_selection : Nil
      @anchor = @position
    end

    def select(type : SelectionType) : Nil
      case type
      when .document?
        set_position(0)
        set_position(@document.size, :keep_anchor)
      when .word_under_cursor?
        from, to = word_bounds
        set_position(from)
        set_position(to, :keep_anchor)
      else # LineUnderCursor / BlockUnderCursor — identical at document level
        bi = block_number
        bp = @document.block_position(bi)
        set_position(bp)
        set_position(bp + @document.blocks[bi].size, :keep_anchor)
      end
    end

    def select_all : Nil
      self.select :document
    end

    # Selected plain text, block separators as `'\n'` (Qt uses U+2029 and
    # converts at the widget boundary; we keep `'\n'` throughout).
    def selected_text : String
      @document.plain_text(selection_start, selection_end)
    end

    # Selected content with formats, for rich copy.
    def selection : TextDocumentFragment
      @document.copy_fragment(selection_start, selection_end)
    end

    # === Position queries ===

    def block_number : Int32
      @document.block_at(@position)[0]
    end

    def position_in_block : Int32
      @document.block_at(@position)[1]
    end

    def block : TextBlock
      @document.blocks[block_number]
    end

    def at_start? : Bool
      @position == 0
    end

    def at_end? : Bool
      @position == @document.size
    end

    def at_block_start? : Bool
      position_in_block == 0
    end

    def at_block_end? : Bool
      position_in_block == block.size
    end

    # === Editing ===

    # Inserts at the cursor, replacing any selection (one undo step); the
    # cursor ends after the inserted text. Format precedence: explicit
    # argument, then pending typing format, then inherited.
    def insert_text(text : String, format : TextCharFormat? = nil) : Nil
      format ||= @pending_format
      if selection?
        @document.begin_edit_block
        remove_selected_text
        @document.insert_text(@position, text, format)
        @document.end_edit_block
      else
        @document.insert_text(@position, text, format)
      end
    end

    # Inserts a formatted fragment at the cursor, replacing any selection —
    # one undo step (Qt `insertFragment`). The cursor ends after the inserted
    # content.
    def insert_fragment(frag : TextDocumentFragment) : Nil
      if selection?
        @document.begin_edit_block
        remove_selected_text
        @document.insert_fragment(@position, frag)
        @document.end_edit_block
      else
        @document.insert_fragment(@position, frag)
      end
    end

    # Ends the current block and starts a new one (Qt `insertBlock`),
    # optionally formatting the new block.
    def insert_block(block_format : TextBlockFormat? = nil) : Nil
      if block_format
        @document.begin_edit_block
        insert_text("\n")
        @document.apply_block_format(@position, @position, block_format)
        @document.end_edit_block
      else
        insert_text("\n")
      end
    end

    def remove_selected_text : Nil
      return unless selection?
      @document.remove(selection_start, selection_end - selection_start)
    end

    # Delete forward (the Del key); removes the selection instead when one exists.
    def delete_char : Nil
      if selection?
        remove_selected_text
      elsif @position < @document.size
        @document.remove(@position, 1)
      end
    end

    # Delete backward (Backspace); removes the selection instead when one exists.
    def delete_previous_char : Nil
      if selection?
        remove_selected_text
      elsif @position > 0
        @document.remove(@position - 1, 1)
      end
    end

    # === Formats ===

    # Format typing at this position would get: the pending format if set,
    # else the preceding character's.
    def char_format : TextCharFormat
      @pending_format || @document.char_format_at(@position)
    end

    def block_format : TextBlockFormat
      block.block_format
    end

    # Replaces the char format of the selection; without a selection, sets
    # the typing format for the next insert (Qt semantics).
    def set_char_format(format : TextCharFormat) : Nil
      if selection?
        @document.apply_char_format(selection_start, selection_end, format)
      else
        @pending_format = format
      end
    end

    # Merges into the selection's char formats; without a selection, merges
    # into the typing format.
    def merge_char_format(format : TextCharFormat) : Nil
      if selection?
        @document.apply_char_format(selection_start, selection_end, format, merge: true)
      else
        @pending_format = char_format.merge(format)
      end
    end

    def set_block_format(format : TextBlockFormat) : Nil
      @document.apply_block_format(selection_start, selection_end, format)
    end

    def merge_block_format(format : TextBlockFormat) : Nil
      @document.apply_block_format(selection_start, selection_end, format, merge: true)
    end

    # === Lists (Qt `createList`/`insertList`/`currentList`) ===

    # Makes the selected blocks (or the current block) items of a new list
    # sharing *format* (undoable). Membership in a previous list is replaced —
    # `merge` overrides `list_format` when the patch specifies one.
    def create_list(format : TextListFormat = TextListFormat.new) : TextList
      merge_block_format(TextBlockFormat.new(list_format: format))
      TextList.new(@document, format)
    end

    # :ditto:
    def create_list(style : TextListFormat::Style) : TextList
      create_list(TextListFormat.new(style: style))
    end

    # Inserts a new block and makes it the first item of a new list (one undo
    # step).
    def insert_list(format : TextListFormat = TextListFormat.new) : TextList
      @document.begin_edit_block
      begin
        insert_block
        create_list(format)
      ensure
        @document.end_edit_block
      end
    end

    # :ditto:
    def insert_list(style : TextListFormat::Style) : TextList
      insert_list(TextListFormat.new(style: style))
    end

    # The list the current block belongs to, as a fresh view — or nil.
    def current_list : TextList?
      block.block_format.list_format.try { |lf| TextList.new(@document, lf) }
    end

    # === Frames (Qt `insertFrame`/`currentFrame`) ===

    # Nests the selected blocks (or the current block) in a new child frame
    # under the frame at the selection start (undoable). Deviation from Qt's
    # `insertFrame` (which splits at the cursor): whole blocks join the frame
    # — a frame boundary is a row boundary on a cell grid.
    def insert_frame(format : TextFrameFormat = TextFrameFormat.new) : TextFrame
      base_block = @document.blocks[@document.block_at(selection_start)[0]]
      path = (base_block.block_format.frame_formats || [] of TextFrameFormat) + [format]
      merge_block_format(TextBlockFormat.new(frame_formats: path))
      TextFrame.new(@document, format, child: true)
    end

    # The innermost frame containing the cursor (Qt `currentFrame`); the
    # root frame when the block is not framed.
    def current_frame : TextFrame
      @document.frame_at(@position)
    end

    # === Undo grouping (delegates to the document) ===

    def begin_edit_block : Nil
      @document.begin_edit_block
    end

    def end_edit_block : Nil
      @document.end_edit_block
    end

    # === Document-edit adjustment ===

    # Shifts position and anchor for an edit of `removed` -> `added` chars at
    # `pos`. Insertions push positions at the insertion point forward (that's
    # how the editing cursor itself advances); positions inside a removed range
    # collapse to its start.
    protected def adjust(pos : Int32, removed : Int32, added : Int32) : Nil
      @position = TextDocument.shift_position(@position, pos, removed, added)
      @anchor = TextDocument.shift_position(@anchor, pos, removed, added)
    end

    protected def rewind_to_start : Nil
      @position = @anchor = 0
      @pending_format = nil
    end

    # === Movement internals ===

    # One application of `op` from `from`; nil when no movement is possible.
    private def one_move(from : Int32, op : MoveOperation) : Int32?
      doc = @document
      case op
      when .no_move?
        from
      when .start?
        from == 0 ? nil : 0
      when .end?
        from == doc.size ? nil : doc.size
      when .left?, .previous_character?
        from > 0 ? from - 1 : nil
      when .right?, .next_character?
        from < doc.size ? from + 1 : nil
      when .word_left?, .previous_word?
        t = word_left_from(from)
        t == from ? nil : t
      when .word_right?, .next_word?
        t = word_right_from(from)
        t == from ? nil : t
      when .start_of_word?
        t = word_bounds_at(from)[0]
        t == from ? nil : t
      when .end_of_word?
        t = word_bounds_at(from)[1]
        t == from ? nil : t
      when .start_of_line?, .start_of_block?
        bp = doc.block_position(doc.block_at(from)[0])
        from == bp ? nil : bp
      when .end_of_line?, .end_of_block?
        bi = doc.block_at(from)[0]
        be = doc.block_position(bi) + doc.blocks[bi].size
        from == be ? nil : be
      when .previous_block?
        bi = doc.block_at(from)[0]
        bi > 0 ? doc.block_position(bi - 1) : nil
      when .next_block?
        bi = doc.block_at(from)[0]
        bi < doc.block_count - 1 ? doc.block_position(bi + 1) : nil
      when .up?
        bi, col = doc.block_at(from)
        return nil if bi == 0
        target = bi - 1
        doc.block_position(target) + Math.min(col, doc.blocks[target].size)
      when .down?
        bi, col = doc.block_at(from)
        return nil if bi == doc.block_count - 1
        target = bi + 1
        doc.block_position(target) + Math.min(col, doc.blocks[target].size)
      else
        raise "unreachable: unhandled MoveOperation #{op}"
      end
    end

    # Whether the character at *i* is a word character. `char_at` is nilable
    # only out of bounds, which every caller's index guard excludes; the
    # unreachable nil reads as non-word rather than crashing.
    private def word_char_at?(i : Int32) : Bool
      (c = @document.char_at(i)) ? TextDocument.word_char?(c) : false
    end

    # Start of the current/previous word: skip separators left, then word
    # chars. Block separators read as `'\n'` and count as non-word, so the
    # scan crosses them.
    private def word_left_from(from : Int32) : Int32
      TextDocument.scan_word_left(from) { |i| !word_char_at?(i) }
    end

    # Start of the next word: skip the rest of the current word, then
    # separators (Qt `WordRight`). Deliberately *word-run then separator-run* —
    # the opposite phase order from the separators-first scan helpers, so it
    # cannot reuse them without moving where the caret lands.
    private def word_right_from(from : Int32) : Int32
      p = from
      sz = @document.size
      while p < sz && word_char_at?(p)
        p += 1
      end
      while p < sz && !word_char_at?(p)
        p += 1
      end
      p
    end

    # {start, end} of the word around `pos`; the preceding word when between
    # words. Collapses to {pos, pos} in whitespace-only surroundings.
    private def word_bounds_at(pos : Int32) : {Int32, Int32}
      s, e = TextDocument.word_run_at(pos, @document.size) { |i| word_char_at?(i) }
      if s == e
        # Not inside a word: take the word ending at or before pos.
        prev = word_left_from(pos)
        return word_bounds_at(prev) if prev != pos
      end
      {s, e}
    end

    private def word_bounds : {Int32, Int32}
      word_bounds_at(@position)
    end
  end
end
