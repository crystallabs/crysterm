require "weak_ref"

module Crysterm
  # A structured, formatted text buffer (Qt `QTextDocument`): the model
  # behind `Widget::TextEdit`, independent of any widget so several views can
  # share one document. See TEXTEDIT.md.
  #
  # Content is the root `TextFrame`'s block list; positions are codepoint
  # indexes into the blocks joined by an implicit `'\n'` separator (one
  # position each), giving `0..size` valid cursor positions. All mutation
  # goes through `TextCursor` or this class's public editing methods, which
  # record undo commands; the `raw_*`/`protected` primitives below them are
  # the command replay surface and do no undo bookkeeping.
  #
  # Live `TextCursor`s register here (weakly) and are position-adjusted on
  # every edit, Qt's guarantee that makes multiple cursors and views safe.
  #
  # Emits `Event::ContentsChanged`, `Event::BlockCountChanged`,
  # `Event::ModificationChanged`, `Event::UndoAvailable`, `Event::RedoAvailable`.
  class TextDocument
    include EventHandler

    # Search behavior for `#find` (Qt `QTextDocument::FindFlags`). Searches
    # are case-insensitive unless `CaseSensitive` (for `Regex` subjects, case
    # comes from the regex itself).
    @[Flags]
    enum FindFlag
      Backward
      CaseSensitive
      WholeWords
    end

    # How an `Event::ContentsChanged` affected document positions — what a
    # view needs to keep its own flat `Int32` caret adjusted the way
    # registered `TextCursor`s are (they get this same treatment internally):
    #
    # - `Edit`: a structural edit; positions at/after it shift (insertions
    #   push forward, positions inside a removed range collapse to its start).
    # - `Format`: format-only; the range re-renders but positions don't move.
    # - `Replace`: the whole content was swapped (`set_plain_text`,
    #   interchange setters); cursors rewind to the start.
    enum ChangeKind
      Edit
      Format
      Replace
    end

    getter undo_stack : TextUndoStack

    # Root frame owning the block list. Lazy so it can capture `self`.
    getter root_frame : TextFrame { TextFrame.new(self) }

    @cursors = [] of WeakRef(TextCursor)
    @block_offsets : Array(Int32)?
    # Memoized `to_plain_text`; dropped on every structural edit (alongside
    # `@block_offsets`) in `finish_edit`, the single choke point for content
    # mutations. Hot for find-as-you-type and the buffer adapter's `value`.
    @plain_cache : String?
    @last_block_count = 1
    @modified = false
    @undo_available = false
    @redo_available = false

    def initialize(text : String = "")
      @undo_stack = TextUndoStack.new
      set_plain_text(text) unless text.empty?
    end

    # The shared word-character class for word motion — the single definition:
    # `TextCursor`'s word ops and `Mixin::TextEditing#word_char?` (the §5
    # buffer-protocol re-base) both use it.
    def self.word_char?(c : Char) : Bool
      c.alphanumeric? || c == '_'
    end

    # Shifts a flat position for an edit of `removed` -> `added` chars at
    # `pos`: insertions at or before the position push it forward; a position
    # inside a removed range collapses to the range start. The single mapping
    # `TextCursor#adjust` and `Mixin::TextEditing::DocumentBuffer` both use to
    # keep positions/carets consistent with an edit.
    def self.shift_position(p : Int32, pos : Int32, removed : Int32, added : Int32) : Int32
      if removed == 0
        p >= pos ? p + added : p
      elsif p <= pos
        p
      elsif p >= pos + removed
        p + added - removed
      else
        pos
      end
    end

    # Two-phase backward word scan from `from`: skip the run of separator
    # positions the block marks (`true`), then the run of non-separators,
    # returning the resulting index. The block classifies a position by index
    # so a caller can source the character however it likes (document
    # `char_at` vs buffer `buf_char`). Shared by `TextCursor` word motion and
    # `Mixin::TextEditing`'s buffer scans.
    def self.scan_word_left(from : Int32, & : Int32 -> Bool) : Int32
      i = from
      while i > 0 && (yield i - 1)
        i -= 1
      end
      while i > 0 && !(yield i - 1)
        i -= 1
      end
      i
    end

    # Forward counterpart of `.scan_word_left`, bounded by `limit`: skip the
    # separator run at `from`, then the run of non-separators.
    def self.scan_word_right(from : Int32, limit : Int32, & : Int32 -> Bool) : Int32
      i = from
      while i < limit && (yield i)
        i += 1
      end
      while i < limit && !(yield i)
        i += 1
      end
      i
    end

    # The `{start, end}` of the word-character run touching `pos` (single-phase
    # scan out in both directions), bounded by `size`. The block classifies a
    # position by index. Empty (`{pos, pos}`) on a non-word position; callers
    # differ only in what they do with that (see `TextCursor#word_bounds_at`'s
    # previous-word fallback vs the mixin's "no word here").
    def self.word_run_at(pos : Int32, size : Int32, & : Int32 -> Bool) : {Int32, Int32}
      s = pos
      while s > 0 && (yield s - 1)
        s -= 1
      end
      e = pos
      while e < size && (yield e)
        e += 1
      end
      {s, e}
    end

    def blocks : Array(TextBlock)
      root_frame.blocks
    end

    # The innermost frame containing *pos* (Qt `frameAt`): a child-frame view
    # from the block's frame path, or the root frame.
    def frame_at(pos : Int32) : TextFrame
      path = blocks[block_at(pos)[0]].block_format.frame_formats
      if path && (inner = path.last?)
        TextFrame.new(self, inner, child: true)
      else
        root_frame
      end
    end

    def block_count : Int32
      blocks.size
    end

    # Length in positions: block sizes plus one per separator.
    def size : Int32
      block_offsets.last + blocks.last.size
    end

    # {block index, block-local offset} for a document position (clamped).
    # A position equal to a block's size is that block's end; the next block
    # starts one position later (past the separator), so the mapping is
    # unambiguous.
    def block_at(pos : Int32) : {Int32, Int32}
      offs = block_offsets
      lo = 0
      hi = offs.size - 1
      while lo < hi
        mid = (lo + hi + 1) // 2
        if offs[mid] <= pos
          lo = mid
        else
          hi = mid - 1
        end
      end
      off = (pos - offs[lo]).clamp(0, blocks[lo].size)
      {lo, off}
    end

    # Document position of block `index`'s first character.
    def block_position(index : Int32) : Int32
      block_offsets[index]
    end

    # Character at `pos`; the separator reads as `'\n'`, end-of-document as nil.
    def char_at(pos : Int32) : Char?
      return nil if pos < 0 || pos >= size
      bi, off = block_at(pos)
      b = blocks[bi]
      off == b.size ? '\n' : b.text[off]
    end

    # Format of the character preceding `pos` (see `TextBlock#char_format_at`).
    def char_format_at(pos : Int32) : TextCharFormat
      bi, off = block_at(pos)
      blocks[bi].char_format_at(off)
    end

    def block_format_at(pos : Int32) : TextBlockFormat
      blocks[block_at(pos)[0]].block_format
    end

    def to_plain_text : String
      @plain_cache ||= blocks.join('\n', &.text)
    end

    # Plain text of `[from, to)`, separators as `'\n'`.
    def plain_text(from : Int32, to : Int32) : String
      from = from.clamp(0, size)
      to = to.clamp(0, size)
      return "" if to <= from
      String.build do |io|
        first = true
        each_block_in(from, to) do |bi, lo, hi|
          io << '\n' unless first
          io << blocks[bi].text[lo, hi - lo]
          first = false
        end
      end
    end

    # Formatted snapshot of `[from, to)` as detached blocks.
    def copy_fragment(from : Int32, to : Int32) : TextDocumentFragment
      from = from.clamp(0, size)
      to = to.clamp(0, size)
      return TextDocumentFragment.new([TextBlock.new]) if to <= from
      parts = [] of TextBlock
      each_block_in(from, to) do |bi, lo, hi|
        parts << blocks[bi].slice(lo, hi)
      end
      TextDocumentFragment.new(parts)
    end

    # Character-format runs of `[from, to)` in absolute positions (separators
    # carry no char format and are skipped). Undo snapshot for format changes.
    def char_format_runs(from : Int32, to : Int32) : Array({Int32, Int32, TextCharFormat})
      runs = [] of {Int32, Int32, TextCharFormat}
      each_block_in(from, to) do |bi, lo, hi|
        bp = block_position(bi)
        blocks[bi].format_runs(lo, hi).each do |(s, e, f)|
          runs << {bp + s, bp + e, f}
        end
      end
      runs
    end

    # Replaces the whole content. Not undoable: the undo stack is cleared and
    # the document becomes unmodified, matching Qt's `setPlainText`; live
    # cursors rewind to the start.
    def set_plain_text(text : String) : Nil
      replace_content(text.split('\n').map { |l| TextBlock.new(l) })
    end

    # Shared tail of `set_plain_text` and the interchange setters
    # (`set_tags`/`set_markdown`/`set_html`): swaps in *new_blocks* wholesale,
    # with `set_plain_text`'s reset semantics (undo stack cleared, cursors
    # rewound, document unmodified). The blocks are adopted, not copied —
    # callers hand over freshly built ones.
    protected def replace_content(new_blocks : Array(TextBlock)) : Nil
      old_size = size
      bs = blocks
      bs.clear
      new_blocks.empty? ? (bs << TextBlock.new) : bs.concat(new_blocks)
      each_cursor &.rewind_to_start
      @undo_stack.clear
      @block_offsets = nil
      finish_edit(0, old_size, size, kind: :replace)
      refresh_undo_state
    end

    def clear : Nil
      set_plain_text("")
    end

    # === Public editing API (undoable). `TextCursor` is the usual caller. ===

    # Inserts `text` at `pos`; `'\n'`s split blocks. Without an explicit
    # format, inherits the format at the insertion point. Returns the number
    # of positions inserted.
    def insert_text(pos : Int32, text : String, format : TextCharFormat? = nil) : Int32
      return 0 if text.empty?
      pos = pos.clamp(0, size)
      format ||= char_format_at(pos)
      raw_insert(pos, text, format)
      @undo_stack.push(TextUndoStack::InsertCommand.new(pos, text, format), self)
      text.size
    end

    # Removes `count` positions starting at `pos`; removals spanning a
    # separator merge the surrounding blocks (the first block's format
    # survives). Returns the removed content.
    def remove(pos : Int32, count : Int32) : TextDocumentFragment
      pos = pos.clamp(0, size)
      count = Math.min(count, size - pos)
      return TextDocumentFragment.new([TextBlock.new]) if count <= 0
      frag = raw_remove(pos, count)
      @undo_stack.push(TextUndoStack::RemoveCommand.new(pos, frag), self)
      frag
    end

    # Inserts a formatted fragment at `pos` — the rich-paste primitive
    # (document half of Qt `QTextCursor::insertFragment`). Undoable. Returns
    # the number of positions inserted. The fragment is only read (inserted
    # blocks are copies), so a caller-held fragment — e.g. the clipboard's —
    # stays valid.
    def insert_fragment(pos : Int32, frag : TextDocumentFragment) : Int32
      return 0 if frag.size == 0
      pos = pos.clamp(0, size)
      # A multi-block insertion at a block start replaces the head block's
      # format with the fragment's (see `raw_insert_fragment`); record the
      # original so undo restores it exactly.
      bi, off = block_at(pos)
      old_bf = off == 0 && frag.blocks.size > 1 ? blocks[bi].block_format : nil
      raw_insert_fragment(pos, frag)
      @undo_stack.push(TextUndoStack::InsertFragmentCommand.new(pos, frag, old_bf), self)
      frag.size
    end

    # Applies (`merge: false`) or merges (`merge: true`, see
    # `TextCharFormat#merge`) a character format over `[from, to)`.
    def apply_char_format(from : Int32, to : Int32, format : TextCharFormat, merge : Bool = false) : Nil
      from = from.clamp(0, size)
      to = to.clamp(0, size)
      return if to <= from
      old_runs = char_format_runs(from, to)
      raw_apply_char_format(from, to, format, merge)
      @undo_stack.push(TextUndoStack::CharFormatCommand.new(from, to, format, merge, old_runs), self)
    end

    # Applies or merges a block format to every block touched by `[from, to]`.
    def apply_block_format(from : Int32, to : Int32, format : TextBlockFormat, merge : Bool = false) : Nil
      from = from.clamp(0, size)
      to = to.clamp(0, size)
      b1 = block_at(from)[0]
      b2 = block_at(to)[0]
      old_formats = (b1..b2).map { |i| {block_position(i), blocks[i].block_format} }
      raw_apply_block_format(from, to, format, merge)
      @undo_stack.push(TextUndoStack::BlockFormatCommand.new(from, to, format, merge, old_formats), self)
    end

    def undo : Bool
      @undo_stack.undo(self)
    end

    def redo : Bool
      @undo_stack.redo(self)
    end

    def undo_available? : Bool
      @undo_stack.undo_available?
    end

    def redo_available? : Bool
      @undo_stack.redo_available?
    end

    # Groups subsequent edits into one undo step (Qt `beginEditBlock`); nests.
    def begin_edit_block : Nil
      @undo_stack.begin_macro
    end

    def end_edit_block : Nil
      @undo_stack.end_macro(self)
    end

    def modified? : Bool
      @modified
    end

    # `modified = false` marks the current state clean (Qt `setModified`);
    # `true` makes every state dirty until the next explicit clean.
    def modified=(value : Bool)
      value ? @undo_stack.mark_dirty : @undo_stack.mark_clean
      refresh_undo_state
    end

    # === Search ===

    # Finds `subject` from position `from`, returning a cursor selecting the
    # match (anchor at start) or nil. `Backward` finds the last match ending
    # at or before `from`. Matches may span blocks (the separator is `'\n'`).
    def find(subject : String, from : Int32 = 0, flags : FindFlag = FindFlag::None) : TextCursor?
      return nil if subject.empty?
      text = to_plain_text
      # Length-preserving 1:1 case fold: `String#downcase` applies Unicode
      # full case mappings (e.g. 'İ' → two codepoints), which would shift the
      # folded indexes out of sync with document positions. Per-char
      # `Char#downcase` keeps one char per char.
      fold = ->(s : String) { String.build { |io| s.each_char { |c| io << c.downcase } } }
      hay = flags.case_sensitive? ? text : fold.call(text)
      nee = flags.case_sensitive? ? subject : fold.call(subject)
      len = nee.size
      if flags.backward?
        best = nil
        i = hay.index(nee)
        while i && i + len <= from
          best = i if word_boundaries_ok?(text, i, len, flags)
          i = hay.index(nee, i + 1)
        end
        found = best
      else
        i = hay.index(nee, from.clamp(0, size))
        while i && !word_boundaries_ok?(text, i, len, flags)
          i = hay.index(nee, i + 1)
        end
        found = i
      end
      found ? selection_cursor(found, found + len) : nil
    end

    # :ditto:
    def find(subject : Regex, from : Int32 = 0, flags : FindFlag = FindFlag::None) : TextCursor?
      text = to_plain_text
      if flags.backward?
        best = nil
        pos = 0
        while (m = subject.match(text, pos))
          s = m.begin(0)
          e = s + m[0].size
          break if e > from
          best = {s, e} if word_boundaries_ok?(text, s, e - s, flags)
          # Standard non-overlapping enumeration: continue past the match (a
          # `s + 1` restart would re-match suffixes, e.g. "3" inside "333").
          pos = e > s ? e : s + 1
        end
        best.try { |(s, e)| selection_cursor(s, e) }
      else
        pos = from.clamp(0, size)
        while (m = subject.match(text, pos))
          s = m.begin(0)
          e = s + m[0].size
          return selection_cursor(s, e) if word_boundaries_ok?(text, s, e - s, flags)
          pos = s + 1
        end
        nil
      end
    end

    # === Raw primitives: structural edits with cursor adjustment and change
    # signals but no undo recording. Callers are the public methods above and
    # `TextUndoStack` command replay — never widgets. ===

    protected def raw_insert(pos : Int32, text : String, format : TextCharFormat) : Nil
      bi, off = block_at(pos)
      block = blocks[bi]
      if text.includes?('\n')
        lines = text.split('\n')
        tail = block.split(off)
        block.insert(block.size, lines.first, format)
        new_blocks = Array(TextBlock).new(lines.size - 1)
        (1..lines.size - 2).each do |i|
          new_blocks << TextBlock.new(lines[i], format, block.block_format)
        end
        tail.insert(0, lines.last, format)
        new_blocks << tail
        blocks[bi + 1, 0] = new_blocks
      else
        block.insert(off, text, format)
      end
      finish_edit(pos, 0, text.size)
    end

    protected def raw_remove(pos : Int32, count : Int32) : TextDocumentFragment
      frag = copy_fragment(pos, pos + count)
      b1, o1 = block_at(pos)
      b2, o2 = block_at(pos + count)
      if b1 == b2
        blocks[b1].remove(o1, count)
      else
        blocks[b1].remove(o1, blocks[b1].size - o1)
        blocks[b2].remove(0, o2)
        blocks[b1].merge_with(blocks[b2])
        blocks[(b1 + 1)..b2] = [] of TextBlock
      end
      finish_edit(pos, count, 0)
      frag
    end

    # Re-inserts a formatted fragment (undo of a removal, later rich paste).
    # Multi-block fragments split the target block; the re-created trailing
    # block takes the fragment's last block format — the inverse of
    # `raw_remove`'s merge, so undo restores block formats exactly. Inserted
    # blocks are copies; the fragment stays detached for future replays.
    protected def raw_insert_fragment(pos : Int32, frag : TextDocumentFragment) : Nil
      return if frag.size == 0
      bi, off = block_at(pos)
      block = blocks[bi]
      fblocks = frag.blocks
      if fblocks.size == 1
        acc = off
        fblocks[0].fragments.each do |f|
          block.insert(acc, f.text, f.format)
          acc += f.size
        end
      else
        tail = block.split(off)
        # At a block start the fragment's first block IS the new head block:
        # its block format (list/table/frame membership) must ride along, or
        # a pasted list/table corrupts. Mid-block (off > 0) the head half
        # legitimately keeps the surrounding block's format.
        block.block_format = fblocks[0].block_format if off == 0
        fblocks[0].fragments.each { |f| block.insert(block.size, f.text, f.format) }
        new_blocks = Array(TextBlock).new(fblocks.size - 1)
        (1...fblocks.size - 1).each { |i| new_blocks << fblocks[i].clone }
        acc = 0
        fblocks.last.fragments.each do |f|
          tail.insert(acc, f.text, f.format)
          acc += f.size
        end
        tail.block_format = fblocks.last.block_format
        new_blocks << tail
        blocks[bi + 1, 0] = new_blocks
      end
      finish_edit(pos, 0, frag.size)
    end

    protected def raw_apply_char_format(from : Int32, to : Int32, format : TextCharFormat, merge : Bool) : Nil
      each_block_in(from, to) do |bi, lo, hi|
        blocks[bi].apply_char_format(lo, hi, format, merge)
      end
      # Qt reports format changes as removed == added == length; cursor
      # positions are unaffected.
      finish_edit(from, to - from, to - from, kind: :format)
    end

    protected def raw_apply_block_format(from : Int32, to : Int32, format : TextBlockFormat, merge : Bool) : Nil
      b1 = block_at(from)[0]
      b2 = block_at(to)[0]
      (b1..b2).each do |i|
        b = blocks[i]
        b.block_format = merge ? b.block_format.merge(format) : format
      end
      finish_edit(from, to - from, to - from, kind: :format)
    end

    protected def raw_set_block_format_at(pos : Int32, format : TextBlockFormat) : Nil
      blocks[block_at(pos)[0]].block_format = format
      finish_edit(pos, 0, 0, kind: :format)
    end

    # === Cursor registry ===

    protected def register_cursor(cursor : TextCursor) : Nil
      @cursors << WeakRef.new(cursor)
    end

    # Re-evaluates undo/redo availability and modified state, emitting the
    # transition events. Called by the undo stack after every push/undo/redo.
    protected def refresh_undo_state : Nil
      ua = @undo_stack.undo_available?
      ra = @undo_stack.redo_available?
      mod = !@undo_stack.clean?
      if ua != @undo_available
        @undo_available = ua
        emit Crysterm::Event::UndoAvailable, ua
      end
      if ra != @redo_available
        @redo_available = ra
        emit Crysterm::Event::RedoAvailable, ra
      end
      if mod != @modified
        @modified = mod
        emit Crysterm::Event::ModificationChanged, mod
      end
    end

    private def block_offsets : Array(Int32)
      @block_offsets ||= begin
        bs = blocks
        arr = Array(Int32).new(bs.size)
        pos = 0
        bs.each do |b|
          arr << pos
          pos += b.size + 1
        end
        arr
      end
    end

    # Yields {block index, local from, local to} for each block overlapping
    # `[from, to)` — the shared range walk under formats, slicing and search.
    private def each_block_in(from : Int32, to : Int32, & : Int32, Int32, Int32 ->) : Nil
      b1, o1 = block_at(from)
      b2, o2 = block_at(to)
      if b1 == b2
        yield b1, o1, o2
      else
        yield b1, o1, blocks[b1].size
        ((b1 + 1)...b2).each { |i| yield i, 0, blocks[i].size }
        yield b2, 0, o2
      end
    end

    private def each_cursor(& : TextCursor ->) : Nil
      @cursors.reject! { |ref| ref.value.nil? }
      @cursors.each do |ref|
        ref.value.try { |c| yield c }
      end
    end

    # Common tail of every raw edit: drop the position index, shift live
    # cursors, emit change signals. `kind` says how positions were affected
    # (`ChangeKind`) — only `Edit` shifts cursors; `Format` reports a changed
    # range but must not move cursors within it, and `Replace` already rewound
    # them. The kind rides on `ContentsChanged` so views can mirror the same
    # adjustment on their own carets.
    private def finish_edit(pos : Int32, removed : Int32, added : Int32, kind : ChangeKind = :edit) : Nil
      @block_offsets = nil
      @plain_cache = nil
      if kind.edit? && (removed > 0 || added > 0)
        each_cursor &.adjust(pos, removed, added)
      end
      if block_count != @last_block_count
        @last_block_count = block_count
        emit Crysterm::Event::BlockCountChanged, block_count
      end
      emit Crysterm::Event::ContentsChanged, pos, removed, added, kind
    end

    private def word_boundaries_ok?(text : String, i : Int32, len : Int32, flags : FindFlag) : Bool
      return true unless flags.whole_words?
      before = i > 0 ? text[i - 1] : nil
      after = i + len < text.size ? text[i + len] : nil
      (before.nil? || !TextDocument.word_char?(before)) &&
        (after.nil? || !TextDocument.word_char?(after))
    end

    private def selection_cursor(from : Int32, to : Int32) : TextCursor
      c = TextCursor.new(self)
      c.set_position(from)
      c.set_position(to, TextCursor::MoveMode::KeepAnchor)
      c
    end
  end
end
