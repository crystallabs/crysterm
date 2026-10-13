require "weak_ref"
require "uri"

module Crysterm
  # A structured, formatted text buffer (Qt `QTextDocument`), independent of
  # any widget so several views can share one document.
  #
  # Content is the root `TextFrame`'s block list; positions are codepoint
  # indexes into the blocks joined by an implicit `'\n'` separator (one
  # position each), giving `0..size` valid cursor positions. All mutation
  # goes through `TextCursor` (obtain one with `#cursor`), which records undo
  # commands; the document-level editing methods it delegates to are
  # protected (Qt parity — `QTextDocument` exposes no positional editing
  # either), and the `raw_*` primitives below them are the command replay
  # surface and do no undo bookkeeping.
  #
  # Live `TextCursor`s register here (weakly) and are position-adjusted on
  # every edit, Qt's guarantee that makes multiple cursors and views safe.
  #
  # Emits `Event::ContentsChanged` (per edit step),
  # `Event::ContentsChangeFinished` (per edit, at its outermost block's end),
  # `Event::BlockCountChanged`, `Event::ModificationChanged`,
  # `Event::UndoAvailable`, `Event::RedoAvailable`.
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

    # How an `Event::ContentsChanged` affected document positions, so a view
    # can adjust its own flat caret the way registered `TextCursor`s are:
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

    # `{block index, block-local offset}` — what `#block_at` locates a
    # document position as. Valid until the next edit (block indexes shift).
    record BlockLocation, index : Int32, offset : Int32

    # Protected: reaching into the stack from outside could `clear` it
    # mid-macro or push a hand-built command whose replay doesn't match the
    # content. The public undo surface is re-exported here — `#undo`, `#redo`,
    # `#undo_available?`, `#redo_available?`, `#modified?`,
    # `#begin_edit_block`/`#end_edit_block`/`#edit`. Lazy so it can hand the
    # stack its owning document.
    protected getter undo_stack : TextUndoStack { TextUndoStack.new(self) }

    # Monotonic content revision (Qt `QTextDocument::revision`): increases on
    # every mutation — content edits, format-only changes, undo/redo replay
    # and whole-content replacement alike — and never on reads. Every
    # mutation funnels through the single `finish_edit` tail, so no edit
    # path can miss the bump; two equal readings therefore guarantee
    # identical content *and* formatting, making the value safe as a cache
    # key (see `TextTable`'s grid memo). Only monotonicity is guaranteed:
    # one logical operation may bump it several times (e.g. a table
    # rebuild), so compare revisions for equality — don't count increments.
    getter revision : Int64 = 0

    # Root frame owning the block list. Lazy so it can capture `self`.
    getter root_frame : TextFrame { TextFrame.new(self) }

    # Where the document's relative resource names count from (Qt
    # `QTextDocument::baseUrl`): the directory of the file the document was
    # read from, or a URL. A view resolves an image's `TextImageFormat#name`
    # against it (`#resolve_url`); `nil` leaves a relative name as written,
    # which is then read from the working directory. Not content: a
    # whole-content replacement (`#set_markdown`) keeps it, as the document
    # is the same document re-filled.
    property base_url : String?

    # *name* made absolute against `#base_url`. A name with a scheme
    # (`https://…`) is itself, a `file:` URL becomes its path, and an
    # absolute path stays; a relative name is joined to the base — resolved
    # as a URL when the base is one (`URI#resolve`), joined as a path
    # otherwise, its percent-encoding undone (`a%20b.png` names `a b.png`).
    # Without a base a relative name is a path from the working directory,
    # decoded the same way: the Markdown parser percent-encodes every
    # destination it reads (`![x](ćevapi.png)` arrives as
    # `%C4%87evapi.png`), so the name as written would miss the file.
    def resolve_url(name : String) : String
      uri = URI.parse(name)
      if scheme = uri.scheme
        return scheme.downcase == "file" ? URI.decode(uri.path) : name
      end
      return name if name.starts_with?('/')
      base = @base_url || return URI.decode(name)
      base_uri = URI.parse(base)
      case base_uri.scheme.try(&.downcase)
      when nil    then File.expand_path(URI.decode(name), base)
      when "file" then File.expand_path(URI.decode(name), URI.decode(base_uri.path))
      else             base_uri.resolve(name).to_s
      end
    rescue URI::Error
      name
    end

    @cursors = [] of WeakRef(TextCursor)

    # Cumulative block lengths (each block's size plus its separator) as a
    # binary indexed tree: a block's document position is a prefix sum and a
    # typing edit re-records one block's length, both O(log blocks) — the
    # shape of Qt's `QFragmentMap`, whose block nodes carry `size_left` sums
    # that `position()` adds up and `setSize()` adjusts. Rebuilt (O(blocks))
    # only when blocks are inserted or removed.
    private class BlockPositions
      @tree : Array(Int32)
      @lengths : Array(Int32)
      getter count : Int32

      # Sum of every length: the document size plus one.
      getter total : Int32

      # The largest power of two not above `count`: where `#find`'s descent
      # starts.
      @top : Int32

      def initialize(blocks : Array(TextBlock))
        n = blocks.size
        @count = n
        top = 1
        while (top << 1) <= n
          top <<= 1
        end
        @top = top
        lengths = Array(Int32).new(n)
        tree = Array(Int32).new(n + 1, 0)
        total = 0
        # Linear build: each node adds its own range sum into its parent.
        i = 1
        while i <= n
          len = blocks.unsafe_fetch(i - 1).size + 1
          lengths << len
          total += len
          tree[i] += len
          j = i + (i & -i)
          tree[j] += tree[i] if j <= n
          i += 1
        end
        @lengths = lengths
        @tree = tree
        @total = total
      end

      # Document position of block *index*: the lengths before it, summed.
      def position(index : Int32) : Int32
        sum = 0
        i = index
        tree = @tree
        while i > 0
          sum += tree.unsafe_fetch(i)
          i -= i & -i
        end
        sum
      end

      # The block holding document position *pos* — the last block whose
      # position is at most *pos* (the last block, for a position past the
      # end) — and *pos* relative to that block's start, from the one descent.
      def locate(pos : Int32) : {Int32, Int32}
        tree = @tree
        idx = 0
        rem = pos
        step = @top
        while step > 0
          nxt = idx + step
          if nxt <= @count && (len = tree.unsafe_fetch(nxt)) <= rem
            idx = nxt
            rem -= len
          end
          step >>= 1
        end
        if idx == @count
          idx -= 1
          rem += @lengths.unsafe_fetch(idx)
        end
        {idx, rem}
      end

      # Records block *index*'s current length (its size plus the separator).
      def set_length(index : Int32, length : Int32) : Nil
        delta = length - @lengths.unsafe_fetch(index)
        return if delta == 0
        @lengths.unsafe_put(index, length)
        @total += delta
        tree = @tree
        i = index + 1
        while i <= @count
          tree.unsafe_put(i, tree.unsafe_fetch(i) + delta)
          i += i & -i
        end
      end
    end

    @block_positions : BlockPositions?

    # Memoized `to_plain_text`; dropped on every edit.
    @plain_cache : String?
    @last_block_count = 1
    @modified = false
    @undo_available = false
    @redo_available = false

    # Whether edits are recorded for undo (Qt `setUndoRedoEnabled`). Setting
    # it false clears the existing undo stack — commands recorded against a
    # content that later unrecorded edits rewrote could not replay safely —
    # and subsequent edits record nothing; importers use it to suppress
    # recording wholesale.
    getter? undo_redo_enabled : Bool = true

    def undo_redo_enabled=(value : Bool) : Bool
      undo_stack.clear unless value == @undo_redo_enabled
      @undo_redo_enabled = value
      refresh_undo_state
      value
    end

    def initialize(text : String = "")
      set_plain_text(text) unless text.empty?
    end

    # The single definition of the word-character class for all word motion.
    def self.word_char?(c : Char) : Bool
      c.alphanumeric? || c == '_'
    end

    # Shifts a flat position for an edit of `removed` -> `added` chars at
    # `pos`: insertions at or before the position push it forward; a position
    # inside a removed range collapses to the range start. The single mapping
    # every caret adjustment goes through.
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
    # positions the block marks (`true`), then the run of non-separators. The
    # block classifies a position by index, so callers can source the character
    # however they like.
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
    # position by index. Empty (`{pos, pos}`) on a non-word position — callers
    # decide what that means.
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

    # The document's blocks in order, as a read-only live view (see
    # `TextBlockView`). Mutation goes through `TextCursor` (see `#cursor`),
    # never the block list directly — a direct push/clear would desynchronize
    # the memoized block offsets and could break the at-least-one-block
    # invariant.
    def blocks : TextBlockView
      TextBlockView.new(blocks_mut)
    end

    # The live storage array behind `#blocks` — for the editing primitives.
    protected def blocks_mut : Array(TextBlock)
      root_frame.root_storage
    end

    # The innermost frame containing *pos* (Qt `frameAt`): a child-frame view
    # from the block's frame path, or the root frame.
    def frame_at(pos : Int32) : TextFrame
      path = find_block(pos).block_format.frame_formats
      if path && (inner = path.last?)
        TextFrame.new(self, inner, child: true)
      else
        root_frame
      end
    end

    def block_count : Int32
      blocks.size
    end

    # Length in positions: block sizes plus one per separator. NOTE: this is
    # Qt's `characterCount` (also exposed as `#character_count`), NOT
    # `QTextDocument::size()` — the latter is a layout (pixel) size, which a
    # cell-grid document has no analogue of.
    def size : Int32
      block_positions.total - 1
    end

    # Alias of `#size`, under Qt's name for the same quantity
    # (`QTextDocument::characterCount`).
    def character_count : Int32
      size
    end

    # Whether the document holds no text at all (a single empty block —
    # `size == 0`; Qt `isEmpty`).
    def empty? : Bool
      size == 0
    end

    # The `BlockLocation` — `{block index, block-local offset}` — of a
    # document position (clamped). A position equal to a block's size is that
    # block's end; the next block starts one position later (past the
    # separator), so the mapping is unambiguous.
    def block_at(pos : Int32) : BlockLocation
      index, off = block_positions.locate(pos)
      BlockLocation.new(index, off.clamp(0, blocks[index].size))
    end

    # The block containing document position *pos* (Qt `findBlock`) — the
    # handle form of `#block_at` for callers that don't need the block-local
    # offset. The returned block answers `#position`/`#block_number`/
    # `#next`/`#previous` against this document.
    def find_block(pos : Int32) : TextBlock
      blocks[block_at(pos).index]
    end

    # Document position of block `index`'s first character.
    def block_position(index : Int32) : Int32
      block_positions.position(index)
    end

    # The index of the block rendered from source *line* (1-based,
    # `TextBlock#source_line`, as the Markdown importer stamps it): the first
    # block stamped with that line — or, for a line that rendered nothing (a
    # blank line, a fence, a table delimiter row), with the nearest line
    # above that did. `nil` above everything rendered, and in a document
    # with no stamps. The source-to-preview direction of a source/preview
    # pair's caret sync; `#source_line_at` is the other.
    #
    # A binary search, as this runs on every caret move of a following
    # view: it relies on the stamps being non-decreasing in document order,
    # which they are as the importer lays them, generated blocks between
    # them aside. A document edited since (blocks moved, not re-imported)
    # gets an approximate answer.
    def block_from_source_line(line : Int32) : Int32?
      lo = 0
      hi = block_count - 1
      best = nil
      while lo <= hi
        mid = (lo + hi) // 2
        # The stamped block nearest below the middle, within the range.
        i = mid
        probe = nil
        while i >= lo && (probe = blocks[i].source_line).nil?
          i -= 1
        end
        if probe.nil?
          lo = mid + 1
        elsif probe <= line
          best = i
          lo = mid + 1
        else
          hi = i - 1
        end
      end
      return unless best
      # Back to the first block stamped with that line.
      stamp = blocks[best].source_line
      j = best - 1
      while j >= 0
        case blocks[j].source_line
        when nil   then j -= 1
        when stamp then best = j; j -= 1
        else            break
        end
      end
      best
    end

    # The block rendered from source *line*, as `#block_from_source_line`
    # finds it — the handle form, after Qt's `findBlockByLineNumber`, for a
    # caller that goes on to the block's `#position`, `#size` or
    # `#source_line` rather than its index. `nil` where the index is.
    def find_block_by_source_line(line : Int32) : TextBlock?
      block_from_source_line(line).try { |i| blocks[i] }
    end

    # The source line block *index* was rendered from — or, for a block the
    # importer generated (a table border, a quote's blank line), the nearest
    # stamped block above's. `nil` with no stamped block at or above.
    def source_line_at(index : Int32) : Int32?
      index.downto(0) do |i|
        if line = blocks[i].source_line
          return line
        end
      end
      nil
    end

    # The source line of the first stamped block after *index*: the block's
    # own source ends on the line before it. `nil` when no block after
    # *index* is stamped.
    def next_source_line_after(index : Int32) : Int32?
      ((index + 1)...block_count).each do |j|
        if line = blocks[j].source_line
          return line
        end
      end
      nil
    end

    # Character at `pos`; the separator reads as `'\n'`, end-of-document as nil.
    def char_at(pos : Int32) : Char?
      return if pos < 0 || pos >= size
      loc = block_at(pos)
      bi = loc.index
      off = loc.offset
      b = blocks[bi]
      off == b.size ? '\n' : b.text[off]
    end

    # Walks the characters at positions `from, from + 1, …` — exactly what
    # repeated `#char_at` would yield, block separators included as `'\n'` —
    # stopping when the block returns false or the document end is reached.
    #
    # The point is that a scan pays the `#block_at` binary search (and the
    # codepoint→byte index walk into the block's text) ONCE, then rides a
    # `Char::Reader` over the block's cached `text` and hops to the next block
    # without re-searching; `#char_at` per position is O(log blocks) plus
    # O(offset) codepoint indexing on a non-ASCII block, i.e. quadratic over a
    # word motion.
    #
    # Boundary cases: a *from* on a separator (`off == block size`, non-last
    # block) yields that `'\n'` first; an empty block contributes only its
    # trailing separator; `from >= size` yields nothing (there is no character
    # at `size`, matching `#char_at`); the last block's end emits no separator.
    def each_char_forward(from : Int32, & : Char -> Bool) : Nil
      sz = size
      from = from.clamp(0, sz)
      return if from >= sz
      bs = blocks
      loc = block_at(from)
      bi = loc.index
      off = loc.offset
      loop do
        b = bs[bi]
        if off < b.size
          t = b.text
          reader = Char::Reader.new(t, t.char_index_to_byte_index(off) || t.bytesize)
          while reader.has_next?
            return unless yield reader.current_char
            reader.next_char
          end
        end
        # Past the block's own text sits its separator, unless it is the last.
        bi += 1
        return if bi >= bs.size
        return unless yield '\n'
        off = 0
      end
    end

    # Backward counterpart of `#each_char_forward`: walks the characters at
    # positions `from - 1, from - 2, …` down to 0 (i.e. *from* is exclusive,
    # the way a backward scan's cursor position is), stopping when the block
    # returns false.
    #
    # Boundary cases: `from <= 0` yields nothing; `from == size` starts at the
    # last block's last character; a *from* on a separator yields the preceding
    # block's last character first (the separator itself sits AT *from*, which
    # is excluded); the separator before block `bi` is emitted after that
    # block's first character and before block `bi - 1`'s last one; an empty
    # block contributes no character, only the separator that precedes it.
    def each_char_backward(from : Int32, & : Char -> Bool) : Nil
      from = from.clamp(0, size)
      return if from <= 0
      bs = blocks
      loc = block_at(from)
      bi = loc.index
      off = loc.offset
      loop do
        b = bs[bi]
        if off > 0
          t = b.text
          reader = Char::Reader.new(t, t.char_index_to_byte_index(off) || t.bytesize)
          while reader.has_previous?
            return unless yield reader.previous_char
          end
        end
        # Before the block's own text sits the separator joining it to the
        # previous block, unless it is the first.
        return if bi == 0
        return unless yield '\n'
        bi -= 1
        off = bs[bi].size
      end
    end

    # Format of the character *preceding* `pos` — what typing at `pos` would
    # look like (Qt `QTextCursor#charFormat` semantics). For the format of the
    # character AT `pos` (aligned with `#char_at` iteration) use
    # `#char_format_of`.
    def typing_format_at(pos : Int32) : TextCharFormat
      loc = block_at(pos)
      blocks[loc.index].typing_format_at(loc.offset)
    end

    # Format of the character AT `pos` — the `#char_at`-aligned reader. Nil at
    # the document end and on a block separator (which, like Qt's paragraph
    # separator, carries no character format of its own).
    def char_format_of(pos : Int32) : TextCharFormat?
      return if pos < 0 || pos >= size
      loc = block_at(pos)
      b = blocks[loc.index]
      return if loc.offset == b.size # the separator
      b.char_format_of(loc.offset)
    end

    def block_format_at(pos : Int32) : TextBlockFormat
      blocks[block_at(pos).index].block_format
    end

    def to_plain_text : String
      @plain_cache ||= blocks.join('\n', &.text)
    end

    # Alias for `#to_plain_text`. Overloads `#plain_text(from, to)`.
    def plain_text : String
      to_plain_text
    end

    # Alias for `#to_markdown`, completing the `markdown`/`markdown=`/
    # `to_markdown`/`set_markdown` quartet mirroring `plain_text`'s.
    def markdown : String
      to_markdown
    end

    # Alias for `#to_html`, completing the `html`/`html=`/`to_html`/
    # `set_html` quartet mirroring `plain_text`'s.
    def html : String
      to_html
    end

    # Alias for `#to_tags`, completing the `tags`/`tags=`/`to_tags`/
    # `set_tags` quartet mirroring `plain_text`'s.
    def tags : String
      to_tags
    end

    # Clamps a `[from, to)` position pair to the valid `0..size` range — the
    # prelude of every range method.
    private def clamp_range(from : Int32, to : Int32) : {Int32, Int32}
      {from.clamp(0, size), to.clamp(0, size)}
    end

    # Plain text of `[from, to)`, separators as `'\n'`.
    def plain_text(from : Int32, to : Int32) : String
      from, to = clamp_range(from, to)
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
      from, to = clamp_range(from, to)
      return TextDocumentFragment.new([TextBlock.new]) if to <= from
      parts = [] of TextBlock
      each_block_in(from, to) do |bi, lo, hi|
        parts << blocks[bi].slice(lo, hi)
      end
      TextDocumentFragment.new(parts)
    end

    # Character-format runs of `[from, to)` in absolute positions; separators
    # carry no char format and are skipped.
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
    # cursors rewind to the start. Returns the assigned text (the interchange
    # setters' shared convention).
    def set_plain_text(text : String) : String
      replace_content(TextDocument.normalize_line_breaks(text).split('\n').map { |l| TextBlock.new(l) })
      text
    end

    # *text* with every line break in it as the `'\n'` that separates a
    # document's blocks: a `"\r\n"` pair and a lone `'\r'` each become one
    # `'\n'`. Qt's `QTextCursor::insertText` (behind `setPlainText`,
    # `QTextDocumentFragment::fromPlainText` and every insertion) takes
    # `'\n'`, `"\r\n"` and `'\r'` alike as a paragraph break, so no block
    # of a `QTextDocument` holds a `'\r'`; the plain-text setters and
    # insertions here put their text through this for the same, and
    # `#to_plain_text` gives `'\n'`s. A text without a `'\r'` is returned
    # as is.
    def self.normalize_line_breaks(text : String) : String
      text.includes?('\r') ? text.gsub(/\r\n?/, "\n") : text
    end

    # `=`-setter spelling of `#set_plain_text`.
    def plain_text=(text : String) : String
      set_plain_text(text)
    end

    # Makes the text *text* by an edit rather than a reset: only what
    # differs is changed, as one undo step (an edit block), so the history
    # stays and an undo takes the whole change back — Qt Creator's reload,
    # which applies the difference from the file on disk as a `ChangeSet`
    # instead of resetting with `setPlainText`. The difference is found line
    # by line (Myers' diff, `LineDiff`) and each changed run of lines is
    # narrowed to the characters that differ, so a cursor, and a view's
    # caret and selection, away from the changes keeps its place in the
    # text; one at the start or the end of a change stays there, and one
    # inside a change goes to its start, as for a selection typed over. The
    # text put in takes the format of the text it replaces where it ends,
    # as typing there would; formats elsewhere are left alone.
    #
    # The modified flag follows the undo stack as after any edit; a caller
    # for whom the new text is the saved one (a reload) sets `#modified=`
    # false after it, making the state after the step the clean one (Qt's
    # `QTextDocumentPrivate::setModified`, `QUndoStack::setClean`), so that
    # undoing the step makes the document modified again. Returns whether
    # anything changed; the same text makes no step at all.
    #
    # The name sets it beside `#set_plain_text`, which replaces the text as
    # a reset: this one replaces it as an edit.
    def replace_plain_text(text : String) : Bool
      text = TextDocument.normalize_line_breaks(text)
      old = to_plain_text
      return false if old == text
      old_lines = LineDiff.lines(old)
      new_lines = LineDiff.lines(text)
      old_starts = LineDiff.offsets(old_lines)
      # Top to bottom, a running *delta* keeping the old positions true, so
      # an undo, which takes the step's edits back in reverse, ends at the
      # first change and puts a caret there.
      delta = 0
      edit do
        LineDiff.diff(old_lines, new_lines).each do |(a, b, c, d)|
          from = old_starts[a]
          was = old_lines[a...b].join
          now = new_lines[c...d].join
          # Narrowed to the characters that differ within the run.
          prefix = LineDiff.common_prefix(was, now)
          suffix = LineDiff.common_suffix(was, now, prefix)
          at = from + delta + prefix
          count = was.size - prefix - suffix
          added = now[prefix, now.size - prefix - suffix]
          # The new text after the old, then the old out: a cursor at the
          # run's start stays there, one inside it goes to the start, and
          # one at its end stays at the end (`.shift_position`) — where a
          # removal first would push every one of them past the new text.
          insert_text(at + count, added) unless added.empty?
          remove(at, count) if count > 0
          delta += added.size - count
        end
      end
      true
    end

    # The line diff behind `#replace_plain_text`: the lines of two texts
    # compared whole, each with its line break (the last without), and the
    # runs of lines that differ found with Myers' algorithm ("An O(ND)
    # Difference Algorithm and Its Variations", 1986) once the lines the
    # texts start and end with in common are set aside. A difference too
    # large to search at a reasonable cost (`MAX_STEPS` lines put in or
    # taken out, or `BUDGET` lines compared) is given up on: the lines
    # between the common start and end are then one run.
    module LineDiff
      # The most lines put in or taken out the search looks for.
      MAX_STEPS = 2000

      # The work, in lines passed over, after which the search gives up.
      BUDGET = 50_000_000_i64

      # A run of lines that differ: the old lines `a...b` that the new
      # lines `c...d` replace (either may be empty).
      alias Hunk = {Int32, Int32, Int32, Int32}

      # *text*'s lines, each with its `'\n'` but the last.
      def self.lines(text : String) : Array(String)
        lines = text.split('\n')
        (0...lines.size - 1).each { |i| lines[i] += "\n" }
        lines
      end

      # Where each of *lines* starts in their text, and the end after them.
      def self.offsets(lines : Array(String)) : Array(Int32)
        starts = Array(Int32).new(lines.size + 1)
        at = 0
        lines.each do |line|
          starts << at
          at += line.size
        end
        starts << at
        starts
      end

      # The runs of lines in which *new* differs from *old*, in order.
      def self.diff(old : Array(String), new : Array(String)) : Array(Hunk)
        head = 0
        while head < old.size && head < new.size && old[head] == new[head]
          head += 1
        end
        tail = 0
        while tail < old.size - head && tail < new.size - head && old[old.size - 1 - tail] == new[new.size - 1 - tail]
          tail += 1
        end
        n = old.size - head - tail
        m = new.size - head - tail
        return [] of Hunk if n == 0 && m == 0
        whole = [{head, head + n, head, head + m}]
        return whole if n == 0 || m == 0
        # The lines as numbers, so the search compares integers.
        ids = {} of String => Int32
        x = Array(Int32).new(n) { |i| ids.put_if_absent(old[head + i]) { ids.size } }
        y = Array(Int32).new(m) { |j| ids.put_if_absent(new[head + j]) { ids.size } }
        myers(x, y, head) || whole
      end

      # Myers' greedy search for the shortest edit script turning *x* into
      # *y* (the lines in between, *base* their first's index), keeping each
      # round's furthest reaching paths to trace the script back; nil when
      # it would cost more than `MAX_STEPS` or `BUDGET`.
      private def self.myers(x : Array(Int32), y : Array(Int32), base : Int32) : Array(Hunk)?
        n, m = x.size, y.size
        max = n + m
        offset = max + 1
        v = Array(Int32).new(2 * max + 3, 0)
        # The paths as each round started, for k in -d-1..d+1 (at k+d+1).
        trace = [] of Array(Int32)
        work = 0_i64
        (0..max).each do |d|
          return if d > MAX_STEPS || work > BUDGET
          trace << v[offset - d - 1, 2 * d + 3]
          (-d..d).step(2) do |k|
            px = if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                   v[offset + k + 1]
                 else
                   v[offset + k - 1] + 1
                 end
            py = px - k
            while px < n && py < m && x[px] == y[py]
              px += 1
              py += 1
            end
            v[offset + k] = px
            return trace_back(trace, n, m, base) if px >= n && py >= m
          end
          work += max
        end
        nil
      end

      # Back from the end of the script along the rounds' paths: each
      # round's step is a line put in or taken out, before a run of equal
      # lines; steps that touch are joined into one run.
      private def self.trace_back(trace : Array(Array(Int32)), px : Int32, py : Int32, base : Int32) : Array(Hunk)
        steps = [] of Hunk
        (trace.size - 1).downto(1) do |d|
          prev = trace[d]
          k = px - py
          down = k == -d || (k != d && prev[k - 1 + d + 1] < prev[k + 1 + d + 1])
          pk = down ? k + 1 : k - 1
          sx = prev[pk + d + 1]
          sy = sx - pk
          steps << (down ? {base + sx, base + sx, base + sy, base + sy + 1} : {base + sx, base + sx + 1, base + sy, base + sy})
          px, py = sx, sy
        end
        steps.reverse!
        hunks = [] of Hunk
        steps.each do |s|
          if (last = hunks.last?) && last[1] == s[0] && last[3] == s[2]
            hunks[-1] = {last[0], s[1], last[2], s[3]}
          else
            hunks << s
          end
        end
        hunks
      end

      # How many characters *a* and *b* start with in common.
      def self.common_prefix(a : String, b : String) : Int32
        ra = Char::Reader.new(a)
        rb = Char::Reader.new(b)
        count = 0
        while ra.has_next? && rb.has_next? && ra.current_char == rb.current_char
          count += 1
          ra.next_char
          rb.next_char
        end
        count
      end

      # How many characters *a* and *b* end with in common, short of their
      # first *skip*.
      def self.common_suffix(a : String, b : String, skip : Int32) : Int32
        ra = Char::Reader.new(at_end: a)
        rb = Char::Reader.new(at_end: b)
        limit = Math.min(a.size, b.size) - skip
        count = 0
        while count < limit && ra.current_char == rb.current_char
          count += 1
          ra.previous_char if ra.has_previous?
          rb.previous_char if rb.has_previous?
        end
        count
      end
    end

    # Swaps in *new_blocks* wholesale with `set_plain_text`'s reset semantics:
    # undo stack cleared, cursors rewound, document unmodified, and a
    # Markdown stream the document was taking forgotten (`#append_markdown`
    # starts over: what it held pending belonged to the text replaced). The
    # blocks are adopted, not copied — callers must hand over freshly built
    # ones.
    protected def replace_content(new_blocks : Array(TextBlock)) : Nil
      forget_markdown_stream
      TextTable.fit_blocks(new_blocks, @text_width)
      old_size = size
      bs = blocks_mut
      bs.clear
      new_blocks.empty? ? (bs << TextBlock.new) : bs.concat(new_blocks)
      adopt(bs)
      each_cursor &.rewind_to_start
      undo_stack.clear
      @block_positions = nil
      edit_step do
        finish_edit(0, old_size, size, kind: :replace)
        refresh_undo_state
      end
    end

    def clear : Nil
      set_plain_text("")
    end

    # === Cursor construction — the public editing route ===

    # A cursor at *pos* (clamped) — `TextCursor.new(self, pos)` with the
    # receiver reading naturally: `doc.cursor(3).insert_text("x")`.
    def cursor(pos : Int32 = 0) : TextCursor
      TextCursor.new(self, pos)
    end

    # A cursor selecting `[from, to)`: anchor at *from*, position at *to* —
    # e.g. `doc.cursor(0, 5).set_char_format(bold)`.
    def cursor(from : Int32, to : Int32) : TextCursor
      TextCursor.new(self, from, to)
    end

    # === Document-level editing (undoable). Protected: the public editing
    # route is `TextCursor` (Qt parity — `QTextDocument` exposes no positional
    # editing either); these are its delegates, shared by the in-tree
    # structure views (`TextTable`, `TextToc`, …). ===

    # Inserts `text` at `pos`; line breaks (`'\n'`, `"\r\n"`, a lone `'\r'`
    # — `.normalize_line_breaks`) split blocks. Without an explicit format,
    # inherits the format at the insertion point. Returns the number of
    # positions inserted.
    protected def insert_text(pos : Int32, text : String, format : TextCharFormat? = nil) : Int32
      return 0 if text.empty?
      text = TextDocument.normalize_line_breaks(text)
      pos = pos.clamp(0, size)
      format ||= typing_format_at(pos)
      edit_step do
        raw_insert(pos, text, format)
        record_undo TextUndoStack::InsertCommand.new(pos, text, format)
      end
      text.size
    end

    # Removes `count` positions starting at `pos`; removals spanning a
    # separator merge the surrounding blocks (the first block's format
    # survives). Returns the removed content.
    protected def remove(pos : Int32, count : Int32) : TextDocumentFragment
      pos = pos.clamp(0, size)
      count = Math.min(count, size - pos)
      return TextDocumentFragment.new([TextBlock.new]) if count <= 0
      frag = edit_step do
        raw_remove(pos, count).tap { |f| record_undo TextUndoStack::RemoveCommand.new(pos, f) }
      end
      # A copy, never the instance the undo record holds: mutating the returned
      # fragment must not rewrite what undo will restore.
      TextDocumentFragment.new(frag.blocks.map(&.clone))
    end

    # Inserts a formatted fragment at `pos` (Qt `QTextCursor::insertFragment`),
    # undoably, returning the number of positions inserted. The fragment is
    # only read and inserted blocks are copies, so a caller-held fragment —
    # e.g. the clipboard's — stays valid.
    protected def insert_fragment(pos : Int32, frag : TextDocumentFragment) : Int32
      return 0 if frag.size == 0
      pos = pos.clamp(0, size)
      # Its tables as tables of their own, at this document's width — on
      # copies, the fragment being the caller's. A table format's identity
      # is its table's, so a pasted table gets a new one (Qt's
      # `QTextCopyHelper` creates the table anew), not one that makes it
      # more rows of the table it was copied from.
      if frag.blocks.any?(&.block_format.table_format)
        copy = frag.blocks.map(&.clone)
        fresh = {} of TextTableFormat => TextTableFormat
        copy.each do |b|
          tf = b.block_format.table_format || next
          b.block_format = b.block_format.merge(TextBlockFormat.new(table_format: fresh[tf] ||= tf.dup))
        end
        TextTable.fit_blocks(copy, @text_width)
        frag = TextDocumentFragment.new(copy)
      end
      # A multi-block insertion at a block start replaces the head block's
      # format with the fragment's; record the original so undo restores it.
      loc = block_at(pos)
      old_bf = loc.offset == 0 && frag.blocks.size > 1 ? blocks[loc.index].block_format : nil
      edit_step do
        raw_insert_fragment(pos, frag)
        record_undo TextUndoStack::InsertFragmentCommand.new(pos, frag, old_bf)
      end
      frag.size
    end

    # Applies (`merge: false`) or merges (`merge: true`, see
    # `TextCharFormat#merge`) a character format over `[from, to)`.
    protected def apply_char_format(from : Int32, to : Int32, format : TextCharFormat, merge : Bool = false) : Nil
      from, to = clamp_range(from, to)
      return if to <= from
      old_runs = char_format_runs(from, to)
      edit_step do
        raw_apply_char_format(from, to, format, merge)
        record_undo TextUndoStack::CharFormatCommand.new(from, to, format, merge, old_runs)
      end
    end

    # Applies or merges a block format to every block touched by `[from, to]`.
    protected def apply_block_format(from : Int32, to : Int32, format : TextBlockFormat, merge : Bool = false) : Nil
      from, to = clamp_range(from, to)
      b1 = block_at(from).index
      b2 = block_at(to).index
      old_formats = (b1..b2).map { |i| {block_position(i), blocks[i].block_format} }
      edit_step do
        raw_apply_block_format(from, to, format, merge)
        record_undo TextUndoStack::BlockFormatCommand.new(from, to, format, merge, old_formats)
      end
    end

    # Pushes an undo command, unless recording is off (`#undo_redo_enabled=`).
    private def record_undo(cmd : TextUndoStack::Command) : Nil
      undo_stack.push(cmd) if @undo_redo_enabled
    end

    # Undoes the last edit step; returns whether anything was undone. Its
    # replay is one change, told of by one `Event::ContentsChangeFinished`
    # after its `ContentsChanged` steps, as Qt's undo runs in an edit block.
    def undo : Bool
      edit_step { undo_stack.undo }
    end

    # Redoes the last undone edit step; returns whether anything was redone.
    # Told of as `#undo` is.
    def redo : Bool
      edit_step { undo_stack.redo }
    end

    # Undoes the last edit step and puts *cursor* where the change was
    # undone (Qt `QTextDocument::undo(QTextCursor*)`): after text it put
    # back, where text it took out was, or after a range whose format it
    # changed, its selection dropped (`TextUndoStack::Command#undo_position`).
    # Raises
    # `ArgumentError` for a cursor on another document, which Qt instead
    # replaces with one on this. Returns whether anything was undone.
    def undo(cursor : TextCursor) : Bool
      replay_into(cursor) { undo }
    end

    # Redoes the last undone edit step and puts *cursor* at the end of the
    # change redone (Qt `QTextDocument::redo(QTextCursor*)`); as `#undo`
    # otherwise.
    def redo(cursor : TextCursor) : Bool
      replay_into(cursor) { redo }
    end

    private def replay_into(cursor : TextCursor, &) : Bool
      raise ArgumentError.new("cursor belongs to another document") unless cursor.document.same?(self)
      return false unless yield
      undo_stack.last_replay_position.try { |p| cursor.set_position(p) }
      true
    end

    def undo_available? : Bool
      undo_stack.undo_available?
    end

    def redo_available? : Bool
      undo_stack.redo_available?
    end

    # Groups subsequent edits into one undo step (Qt `beginEditBlock`); nests.
    # The edits are told of step by step (`Event::ContentsChanged`) and, when
    # the outermost block ends, once as a whole
    # (`Event::ContentsChangeFinished`).
    def begin_edit_block : Nil
      @edit_depth += 1
      undo_stack.begin_macro
    end

    # Ends the block `#begin_edit_block` opened (Qt `endEditBlock`); the end
    # of the outermost one emits `Event::ContentsChangeFinished` when
    # anything in it changed. Without an open block it does nothing.
    def end_edit_block : Nil
      return if @edit_depth == 0
      undo_stack.end_macro
      @edit_depth -= 1
      finish_contents_change if @edit_depth == 0
    end

    # How many edit blocks, or operations of several steps (`#edit_step`),
    # are open: `Event::ContentsChangeFinished` waits for the last to end.
    # Kept apart from the undo stack's macro depth, which an undo stack
    # cleared mid-block (`#set_plain_text`, `#undo_redo_enabled=`) resets.
    @edit_depth = 0

    # Set by an edit step made while an edit is open (`@edit_depth`), so its
    # end emits `Event::ContentsChangeFinished` (Qt's `docChangeFrom >= 0`).
    @contents_change_pending = false

    # Runs the block as one edit, as an edit block does but recording no undo
    # macro of its own: the steps it makes emit their `ContentsChanged` as
    # they are made and one `ContentsChangeFinished` at its end, after the
    # undo command it records and the undo state's events — Qt's order, where
    # `modificationChanged` comes before `contentsChanged`. An undo and a
    # redo run in one, as Qt's run in an edit block: opening no undo macro,
    # it leaves them free to run (`TextUndoStack#undo` refuses inside one).
    private def edit_step(& : -> U) : U forall U
      @edit_depth += 1
      begin
        result = yield
      ensure
        @edit_depth -= 1
      end
      finish_contents_change if @edit_depth == 0
      result
    end

    # Emits `Event::ContentsChangeFinished` when an edit step was made since
    # the last; run once no edit is open (Qt's `QTextDocumentPrivate::
    # contentsChanged`, from `finishEdit`).
    private def finish_contents_change : Nil
      return unless @contents_change_pending
      @contents_change_pending = false
      emit Crysterm::Event::ContentsChangeFinished
    end

    # Block form of `#begin_edit_block`/`#end_edit_block`: yields the document
    # and returns the block's value, closing the undo macro on every exit path.
    # Prefer this over the manual pair — a raise between a manual `begin`/`end`
    # leaves the macro open forever, permanently disabling `#undo`/`#redo`
    # (they no-op while `in_macro?`).
    def edit(& : self -> U) : U forall U
      begin_edit_block
      begin
        yield self
      ensure
        end_edit_block
      end
    end

    def modified? : Bool
      @modified
    end

    # `modified = false` marks the current state clean (Qt `setModified`);
    # `true` makes every state dirty until the next explicit clean.
    def modified=(value : Bool)
      value ? undo_stack.mark_dirty : undo_stack.mark_clean
      refresh_undo_state
    end

    # === Search ===

    # Finds `subject` from position `from`, returning a cursor selecting the
    # match (anchor at start) or nil. Forward, the first match starting at or
    # after `from`; a `from` past the end finds nothing (it is not pulled back
    # to the end, so a caller stepping past a match at the end stops).
    # `Backward` finds the last match starting before `from`, which may end
    # past it: a match `from` is inside is found from its start, as Qt's
    # `QTextDocument::find` with `FindBackward` (searching back from the
    # position before `from`) and Vim's `?` find it. A caller stepping back
    # through the matches passes the current match's start, as Qt's cursor
    # overload passes `selectionStart`. Matches may span blocks (the
    # separator is `'\n'`, one position like any character).
    #
    # A `Regex` may match the empty string (`/x*/`, `/^/`, `/$/m`): the
    # cursor then selects nothing and sits where the match is, as Qt's does.
    # A caller walking the matches resumes at the match's end or one past
    # its start, whichever is further — moving at least one position, or an
    # empty match would be found again where it is. Backward the step is
    # built in: an empty match at `from` itself does not count, so searching
    # back from a match's start always moves (from 0 it finds nothing, like
    # Qt's backward search from the start).
    def find(subject : String, from : Int32 = 0, flags : FindFlag = FindFlag::None) : TextCursor?
      return if subject.empty?
      return if from > size && !flags.backward?
      text = to_plain_text
      # Length-preserving 1:1 case fold: `String#downcase` applies Unicode
      # full case mappings (e.g. 'İ' → two codepoints), which would shift the
      # folded indexes out of sync with document positions. Per-char
      # `Char#downcase` keeps one char per char.
      fold = ->(s : String) { String.build { |io| s.each_char { |c| io << c.downcase } } }
      hay = flags.case_sensitive? ? text : fold.call(text)
      nee = flags.case_sensitive? ? subject : fold.call(subject)
      len = nee.size
      # The candidates are walked by byte offset (`String#byte_index`): a
      # char index costs a scan from the start of a text with non-ASCII, so
      # a walk by char index is quadratic in it. The fold keeps a char's
      # word class, so the folded text's boundaries are the text's.
      nb = nee.bytesize
      if flags.backward?
        return if from <= 0
        limit = from >= hay.size ? hay.bytesize : hay.char_index_to_byte_index(from) || return
        best = nil
        b = hay.byte_index(nee)
        while b && b < limit
          best = b if word_boundaries_ok?(hay, b, b + nb, flags)
          b = hay.byte_index(nee, b + 1)
        end
        found = best
      else
        b = hay.char_index_to_byte_index(from.clamp(0, size)).try { |start| hay.byte_index(nee, start) }
        while b && !word_boundaries_ok?(hay, b, b + nb, flags)
          b = hay.byte_index(nee, b + 1)
        end
        found = b
      end
      return unless found
      i = hay.byte_index_to_char_index(found) || return
      selection_cursor(i, i + len)
    end

    # :ditto:
    def find(subject : Regex, from : Int32 = 0, flags : FindFlag = FindFlag::None) : TextCursor?
      text = to_plain_text
      if flags.backward?
        from = Math.min(from, text.size)
        return if from <= 0
        limit = from == text.size ? text.bytesize : text.char_index_to_byte_index(from) || return
        best = nil
        pos = 0
        # The matches are enumerated over the whole text, as Qt's
        # `lastIndexOf` enumerates a block's, so a match may run past `from`
        # and anchors and word boundaries read the text that follows it.
        # By byte offset, as the `String` overload walks.
        while pos <= text.bytesize && (m = subject.match_at_byte_index(text, pos))
          s = m.byte_begin(0)
          break unless s < limit
          e = m.byte_end(0)
          best = {s, e} if word_boundaries_ok?(text, s, e, flags)
          # Standard non-overlapping enumeration: continue past the match (a
          # `s + 1` restart would re-match suffixes, e.g. "3" inside "333").
          pos = e > s ? e : s + next_char_bytesize(text, s)
        end
        best.try { |(s, e)| byte_selection_cursor(text, s, e) }
      else
        return if from > text.size
        pos = text.char_index_to_byte_index(Math.max(from, 0)) || return
        while pos <= text.bytesize && (m = subject.match_at_byte_index(text, pos))
          s = m.byte_begin(0)
          e = m.byte_end(0)
          return byte_selection_cursor(text, s, e) if word_boundaries_ok?(text, s, e, flags)
          pos = s + next_char_bytesize(text, s)
        end
        nil
      end
    end

    # === Raw primitives: structural edits with cursor adjustment and change
    # signals but no undo recording. Only the public methods above and undo
    # command replay may call these — never widgets. ===

    protected def raw_insert(pos : Int32, text : String, format : TextCharFormat) : Nil
      loc = block_at(pos)
      bi = loc.index
      off = loc.offset
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
        adopt(new_blocks)
        blocks_mut[bi + 1, 0] = new_blocks
      else
        block.insert(off, text, format)
      end
      finish_edit(pos, 0, text.size)
    end

    protected def raw_remove(pos : Int32, count : Int32) : TextDocumentFragment
      frag = copy_fragment(pos, pos + count)
      loc = block_at(pos)
      b1 = loc.index
      o1 = loc.offset
      loc = block_at(pos + count)
      b2 = loc.index
      o2 = loc.offset
      if b1 == b2
        blocks[b1].remove(o1, count)
      else
        blocks[b1].remove(o1, blocks[b1].size - o1)
        blocks[b2].remove(0, o2)
        blocks[b1].merge_with(blocks[b2])
        blocks_mut[(b1 + 1)..b2] = [] of TextBlock
      end
      finish_edit(pos, count, 0)
      frag
    end

    # Re-inserts a formatted fragment. Multi-block fragments split the target
    # block; the re-created trailing block takes the fragment's last block
    # format — the exact inverse of `raw_remove`'s merge, so undo restores
    # block formats. Inserted blocks are copies, keeping the fragment detached
    # for future replays.
    protected def raw_insert_fragment(pos : Int32, frag : TextDocumentFragment) : Nil
      return if frag.size == 0
      loc = block_at(pos)
      bi = loc.index
      off = loc.offset
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
        # At a block start the fragment's first block IS the new head block, so
        # its block format (list/table/frame membership) must ride along or a
        # pasted list/table corrupts. Mid-block, the head half keeps the
        # surrounding block's format.
        if off == 0
          block.block_format = fblocks[0].block_format
          block.source_line = fblocks[0].source_line
          block.table_cells_entry = fblocks[0].table_cells_entry
        end
        fblocks[0].fragments.each { |f| block.insert(block.size, f.text, f.format) }
        new_blocks = Array(TextBlock).new(fblocks.size - 1)
        (1...fblocks.size - 1).each { |i| new_blocks << fblocks[i].clone }
        acc = 0
        fblocks.last.fragments.each do |f|
          tail.insert(acc, f.text, f.format)
          acc += f.size
        end
        tail.block_format = fblocks.last.block_format
        tail.source_line = fblocks.last.source_line
        # The tail's cells: at a block start the tail is that block moved
        # down, so it keeps its own (`#split` copies them); past it, the
        # tail is the fragment's last block with the split one's rest, so
        # it takes that block's, none included — an undo putting back a
        # row's text puts back its cells, never the split row's, which
        # another row rendering alike would read as its own.
        tail.table_cells_entry = fblocks.last.table_cells_entry if off > 0
        new_blocks << tail
        adopt(new_blocks)
        blocks_mut[bi + 1, 0] = new_blocks
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
      b1 = block_at(from).index
      b2 = block_at(to).index
      (b1..b2).each do |i|
        b = blocks[i]
        b.block_format = merge ? b.block_format.merge(format) : format
      end
      finish_edit(from, to - from, to - from, kind: :format)
    end

    protected def raw_set_block_format_at(pos : Int32, format : TextBlockFormat) : Nil
      blocks[block_at(pos).index].block_format = format
      finish_edit(pos, 0, 0, kind: :format)
    end

    # === Cursor registry ===

    protected def register_cursor(cursor : TextCursor) : Nil
      @cursors << WeakRef.new(cursor)
    end

    # Stamps this document as *blocks*' owner (see `TextBlock#document`) —
    # run at every point blocks enter the storage.
    protected def adopt(blocks : Enumerable(TextBlock)) : Nil
      blocks.each(&.document=(self))
    end

    # Revision bump for block-overlay writes (`TextBlock#user_state=`/
    # `#additional_formats=`): caches keyed on `#revision` must observe them
    # and views repaint off the zero-length poke, but positions don't move
    # and no undo is recorded — overlays are presentation, not content.
    protected def note_overlay_change : Nil
      @revision += 1
      emit Crysterm::Event::ContentsChanged, 0, 0, 0, ChangeKind::Format
    end

    # Re-evaluates undo/redo availability and modified state, emitting the
    # transition events. Must run after every push/undo/redo.
    protected def refresh_undo_state : Nil
      ua = undo_stack.undo_available?
      ra = undo_stack.redo_available?
      mod = !undo_stack.clean?
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

    private def block_positions : BlockPositions
      @block_positions ||= BlockPositions.new(blocks_mut)
    end

    # Keeps the block position tree current across an edit. An edit that left
    # the block count alone re-records only the lengths of the blocks the
    # edited range `[pos, pos + added]` spans — one block, for a keystroke;
    # a format-only change touches no length; an edit that inserted or
    # removed blocks drops the tree, rebuilt by the next position query.
    private def sync_block_positions(pos : Int32, added : Int32, kind : ChangeKind) : Nil
      bp = @block_positions
      return unless bp
      return if kind.format?
      bs = blocks_mut
      if kind.replace? || bp.count != bs.size
        @block_positions = nil
        return
      end
      # Positions before the edit are unchanged, so the tree still locates
      # the block the edit started in. A block starting exactly at the
      # edit's end is still re-recorded: a block run replaced by one of the
      # same count can end in an empty block (a refreshed TOC's placeholder),
      # which begins at `finish` and whose length changed all the same.
      i = bp.locate(pos)[0]
      finish = pos + added
      loop do
        bp.set_length(i, bs.unsafe_fetch(i).size + 1)
        i += 1
        break if i >= bs.size || bp.position(i) > finish
      end
    end

    # Yields {block index, local from, local to} for each block overlapping
    # `[from, to)`.
    private def each_block_in(from : Int32, to : Int32, & : Int32, Int32, Int32 ->) : Nil
      loc = block_at(from)
      b1 = loc.index
      o1 = loc.offset
      loc = block_at(to)
      b2 = loc.index
      o2 = loc.offset
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

    # Common tail of every raw edit: bring the block positions up to date,
    # shift live cursors, emit change signals: `ContentsChanged` for the
    # step, and `ContentsChangeFinished` too unless an edit is open
    # (`@edit_depth`), whose end emits it. Only `Edit` shifts cursors —
    # `Format` reports a changed range but must not move cursors within it,
    # and `Replace` has already rewound them. The kind rides on
    # `ContentsChanged` so views can mirror the adjustment on their own carets.
    #
    # *remap*, when given, is where each position goes instead of the shift
    # (a table's re-rendering, `#raw_rerender_block_run`); handlers of the
    # change read it through `#position_after_change`.
    private def finish_edit(pos : Int32, removed : Int32, added : Int32, kind : ChangeKind = :edit, remap : Proc(Int32, Int32)? = nil) : Nil
      @revision += 1
      sync_block_positions(pos, added, kind)
      @plain_cache = nil
      if kind.edit? && (removed > 0 || added > 0)
        if remap
          each_cursor &.remap(remap)
        else
          each_cursor &.adjust(pos, removed, added)
        end
      end
      if block_count != @last_block_count
        @last_block_count = block_count
        emit Crysterm::Event::BlockCountChanged, block_count
      end
      @position_remap = remap
      begin
        emit Crysterm::Event::ContentsChanged, pos, removed, added, kind
      ensure
        @position_remap = nil
      end
      @contents_change_pending = true
      finish_contents_change if @edit_depth == 0
    end

    @position_remap : Proc(Int32, Int32)?

    # Where position *p* goes in the `ChangeKind::Edit` change
    # `Event::ContentsChanged` is reporting (*pos*, *removed*, *added*):
    # `.shift_position`, except for a table's re-rendering to a new
    # `#text_width`, where a position in a cell stays in that cell. For a
    # view keeping its own caret, as `TextCursor`s are kept; valid while the
    # change is being reported.
    def position_after_change(p : Int32, pos : Int32, removed : Int32, added : Int32) : Int32
      if remap = @position_remap
        remap.call(p)
      else
        TextDocument.shift_position(p, pos, removed, added)
      end
    end

    # Whether the match at byte offsets `[from, to)` of *text* stands on
    # word boundaries, or *flags* do not ask for them.
    private def word_boundaries_ok?(text : String, from : Int32, to : Int32, flags : FindFlag) : Bool
      return true unless flags.whole_words?
      before = from > 0 ? Char::Reader.new(text, from).previous_char : nil
      after = to < text.bytesize ? Char::Reader.new(text, to).current_char : nil
      (before.nil? || !TextDocument.word_char?(before)) &&
        (after.nil? || !TextDocument.word_char?(after))
    end

    # The byte size of the char at byte offset *at* of *text* — at least 1,
    # so a walk past an empty match at the end moves too.
    private def next_char_bytesize(text : String, at : Int32) : Int32
      at < text.bytesize ? Char::Reader.new(text, at).current_char_width : 1
    end

    private def selection_cursor(from : Int32, to : Int32) : TextCursor
      TextCursor.new(self, from, to)
    end

    # `#selection_cursor` for byte offsets `[from, to)` of *text*.
    private def byte_selection_cursor(text : String, from : Int32, to : Int32) : TextCursor
      s = text.byte_index_to_char_index(from) || 0
      selection_cursor(s, s + text.byte_slice(from, to - from).size)
    end
  end
end
