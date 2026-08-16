module Crysterm
  # One paragraph of a `TextDocument` (Qt `QTextBlock`): an ordered list of
  # `TextFragment` runs plus a `TextBlockFormat`. Blocks never contain the
  # `'\n'` separator — that lives implicitly between consecutive blocks and
  # counts as one position in document coordinates.
  #
  # Offsets here are block-local codepoint indexes, `0..size`. Mutators keep
  # the fragment list normalized (no empty runs, adjacent same-appearance runs
  # merged), so fragment counts are stable.
  #
  # Unlike Qt — where QTextBlock is a lightweight handle into piece-table
  # storage — this is the storage itself.
  class TextBlock
    @fragments : Array(TextFragment)

    # The block's runs, as a read-only view — the fragment list must stay
    # normalized (no empty runs, adjacent same-appearance runs merged) and in
    # sync with the block's text/size caches, which only this block's own
    # mutators maintain.
    def fragments : TextFragmentView
      TextFragmentView.new(@fragments)
    end

    # The live array behind `#fragments`, for the block/document editing
    # internals.
    protected def fragments_mut : Array(TextFragment)
      @fragments
    end

    # The setter is protected: a direct assignment on an adopted block records
    # no undo command and bumps no document revision — the cache key
    # `TextList`/`TextTable`/`TextDocument#outline` memoize against — so views
    # could serve stale results. Use `TextDocument#apply_block_format` (or
    # build detached blocks with the format up front, as the importers do).
    getter block_format : TextBlockFormat
    protected setter block_format

    # Highlighter scratch state (Qt `userState`): e.g. "still inside a
    # multi-line comment". -1 = unset.
    getter user_state : Int32 = -1

    # A change also bumps the owning document's revision (`note_overlay_change`)
    # so revision-keyed caches can't serve results computed before it.
    def user_state=(value : Int32) : Int32
      return value if value == @user_state
      @user_state = value
      document.try(&.note_overlay_change)
      value
    end

    # Overlay format runs `{from, to, patch}` a `SyntaxHighlighter` laid over
    # this block (Qt's layout `additionalFormats`): purely presentational,
    # never merged into the fragments, so highlighting doesn't touch the
    # document content, undo stack, or interchange output.
    getter additional_formats : Array({Int32, Int32, TextCharFormat})?

    # Also invalidates the `render_runs` cache, whose output depends on this
    # overlay, and bumps the owning document's revision (`note_overlay_change`)
    # so revision-keyed caches observe the new overlay. Change-guarded: an
    # equal overlay is a no-op (no bump, no repaint poke).
    def additional_formats=(value : Array({Int32, Int32, TextCharFormat})?) : Array({Int32, Int32, TextCharFormat})?
      return @additional_formats if value == @additional_formats
      @render_runs_cache = nil
      @additional_formats = value
      document.try(&.note_overlay_change)
      @additional_formats
    end

    # The document this block belongs to, nil while detached (importers build
    # blocks detached; the document stamps itself on adoption). Weak, like the
    # cursor registry — a block must not keep its document alive.
    @document : WeakRef(TextDocument)?

    def document : TextDocument?
      @document.try(&.value)
    end

    protected def document=(doc : TextDocument) : Nil
      @document = WeakRef.new(doc)
    end

    @text_cache : String?
    @size_cache : Int32?
    @render_runs_cache : Array({Int32, Int32, TextCharFormat})?

    def initialize(
      text : String = "",
      char_format : TextCharFormat = TextCharFormat.default,
      @block_format : TextBlockFormat = TextBlockFormat.default,
    )
      @fragments = [] of TextFragment
      @fragments << TextFragment.new(text, char_format) unless text.empty?
    end

    def initialize(@fragments : Array(TextFragment), @block_format : TextBlockFormat = TextBlockFormat.default)
      normalize!
    end

    # Length in codepoints — WITHOUT the trailing block separator, unlike
    # Qt's `QTextBlock::length()`, which counts it. `size + 1` is the
    # distance to the next block's start in document positions.
    def size : Int32
      @size_cache ||= @fragments.sum(0, &.size)
    end

    # === Handle surface (Qt `QTextBlock`'s navigational API). Meaningful
    # only on a block adopted by a document; identity-based, so the answers
    # track edits (indexes are recomputed per call). ===

    # This block's index in its document (Qt `blockNumber`). Raises when the
    # block is detached or no longer part of its document.
    def block_number : Int32
      doc = document || raise "TextBlock#block_number: block is not part of a document"
      doc.blocks.index(&.same?(self)) ||
        raise "TextBlock#block_number: block is no longer part of its document"
    end

    # Document position of this block's first character (Qt `position`).
    # Raises like `#block_number` when the block is not in a document.
    def position : Int32
      doc = document || raise "TextBlock#position: block is not part of a document"
      doc.block_position(block_number)
    end

    # The next block in the document, or nil for the last one (or a detached
    # block) — Qt `next` (`Iterator#next` establishes the name's precedent
    # for Crystal method definitions).
    def next : TextBlock?
      doc = document || return
      i = doc.blocks.index(&.same?(self)) || return
      doc.blocks[i + 1]?
    end

    # The previous block in the document, or nil for the first one (or a
    # detached block) — Qt `previous`.
    def previous : TextBlock?
      doc = document || return
      i = doc.blocks.index(&.same?(self)) || return
      i > 0 ? doc.blocks[i - 1] : nil
    end

    def empty? : Bool
      @fragments.empty?
    end

    # Concatenated plain text. Cached; mutators invalidate.
    def text : String
      @text_cache ||= String.build do |io|
        @fragments.each { |f| io << f.text }
      end
    end

    # Deep copy: the fragment list is fresh, while strings and formats are
    # immutable and shared.
    def clone : TextBlock
      TextBlock.new(@fragments.map { |f| TextFragment.new(f.text, f.format) }, @block_format)
    end

    # Format of the character *preceding* `offset` (Qt `QTextCursor#charFormat`
    # semantics: what typing at this position would look like); the first
    # character's format at offset 0, default for an empty block. The
    # at-position counterpart is `#char_format_of`.
    def typing_format_at(offset : Int32) : TextCharFormat
      return TextCharFormat.default if @fragments.empty?
      return @fragments.first.format if offset <= 0
      fi, local = locate(offset)
      local == 0 ? @fragments[fi - 1].format : @fragments[fi].format
    end

    # Format of the character AT `offset` — aligned with `text[offset]`
    # iteration, unlike `#typing_format_at`. Nil past the last character.
    def char_format_of(offset : Int32) : TextCharFormat?
      return if offset < 0 || offset >= size
      fi, _local = locate(offset)
      @fragments[fi].format
    end

    # Inserts `str` at `offset`. Without an explicit format, inherits the
    # format at the insertion point (Qt typing behavior).
    def insert(offset : Int32, str : String, format : TextCharFormat? = nil) : Nil
      return if str.empty?
      offset = offset.clamp(0, size)
      format ||= typing_format_at(offset)
      idx = split_fragment_at(offset)
      @fragments.insert(idx, TextFragment.new(str, format))
      normalize!
    end

    # Removes up to `count` codepoints starting at `offset`.
    def remove(offset : Int32, count : Int32) : Nil
      offset = offset.clamp(0, size)
      to = Math.min(offset + count, size)
      return if to <= offset
      i1 = split_fragment_at(offset)
      i2 = split_fragment_at(to)
      @fragments[i1...i2] = [] of TextFragment
      normalize!
    end

    # Iterates the fragments overlapping block-local range `[from, to)`,
    # yielding each overlapping fragment *f*, its own block-local start
    # `fstart`, and its bounds clamped to the range — `clip_from`/`clip_to`,
    # still in block-local (not fragment-local) coordinates. Shared walk behind
    # `#slice` and `#format_runs`, mirroring `TextDocument#each_block_in`:
    # skips a fragment ending at-or-before `from` (`fend <= from`, no overlap)
    # and stops at the first fragment starting at-or-after `to` (`fstart >=
    # to`) — fragments are visited in ascending order, so this is a genuine
    # early exit once the range is exhausted, not a filter. `from > to` yields
    # nothing (every fragment's `fstart >= to` immediately, since `to` clamps
    # nothing here — callers are expected to pass an already-ordered range);
    # `from == to` yields any fragment straddling that point with
    # `clip_from == clip_to` (an empty clip).
    private def each_fragment_overlap(from : Int32, to : Int32, &)
      acc = 0
      @fragments.each do |f|
        fstart = acc
        fend = acc + f.size
        acc = fend
        next if fend <= from
        break if fstart >= to
        yield f, fstart, Math.max(fstart, from), Math.min(fend, to)
      end
    end

    # Non-destructive copy of the `[from, to)` range as a new block, with the
    # same block format.
    def slice(from : Int32, to : Int32) : TextBlock
      frags = [] of TextFragment
      each_fragment_overlap(from, to) do |f, fstart, clip_from, clip_to|
        s = clip_from - fstart
        e = clip_to - fstart
        frags << TextFragment.new(f.text[s, e - s], f.format)
      end
      TextBlock.new(frags, @block_format)
    end

    # Clamps a `[from, to)` position pair to the valid `0..size` range.
    private def clamp_range(from : Int32, to : Int32) : {Int32, Int32}
      {from.clamp(0, size), to.clamp(0, size)}
    end

    # Applies (or merges) `format` over `[from, to)`.
    def apply_char_format(from : Int32, to : Int32, format : TextCharFormat, merge : Bool = false) : Nil
      from, to = clamp_range(from, to)
      return if to <= from
      i1 = split_fragment_at(from)
      i2 = split_fragment_at(to)
      (i1...i2).each do |i|
        f = @fragments[i]
        f.format = merge ? f.format.merge(format) : format
      end
      normalize!
    end

    # Format runs overlapping `[from, to)` in block-local coordinates, clipped
    # to the range.
    def format_runs(from : Int32, to : Int32) : Array({Int32, Int32, TextCharFormat})
      runs = [] of {Int32, Int32, TextCharFormat}
      each_fragment_overlap(from, to) do |f, _fstart, clip_from, clip_to|
        runs << {clip_from, clip_to, f.format}
      end
      runs
    end

    # What the renderer paints: the block's format runs with
    # `additional_formats` merged over the fragments' own formats, with
    # equal-appearance neighbors coalesced. Plain `format_runs(0, size)` when
    # no overlay is set.
    def render_runs : Array({Int32, Int32, TextCharFormat})
      if cached = @render_runs_cache
        return cached
      end
      @render_runs_cache = compute_render_runs
    end

    private def compute_render_runs : Array({Int32, Int32, TextCharFormat})
      base = format_runs(0, size)
      add = @additional_formats
      return base if add.nil? || add.empty?

      sz = size
      bounds = [] of Int32
      base.each do |(s, e, _)|
        bounds << s << e
      end
      add.each do |(s, e, _)|
        bounds << s.clamp(0, sz) << e.clamp(0, sz)
      end
      bounds.uniq!.sort!

      runs = [] of {Int32, Int32, TextCharFormat}
      bi = 0
      (0...bounds.size - 1).each do |i|
        a = bounds[i]
        b = bounds[i + 1]
        next if b <= a
        while bi < base.size && base[bi][1] <= a
          bi += 1
        end
        fmt = bi < base.size && base[bi][0] <= a ? base[bi][2] : TextCharFormat.default
        add.each do |(s, e, patch)|
          fmt = fmt.merge(patch) if s <= a && a < e
        end
        if (last = runs.last?) && last[1] == a && last[2].same_appearance?(fmt)
          runs[-1] = {last[0], b, last[2]}
        else
          runs << {a, b, fmt}
        end
      end
      runs
    end

    # Truncates this block at `offset` and returns the remainder as a new
    # block. The tail inherits the block format (Qt: pressing Enter carries
    # the paragraph format forward) but not `user_state`.
    def split(offset : Int32) : TextBlock
      offset = offset.clamp(0, size)
      idx = split_fragment_at(offset)
      tail = @fragments[idx..]
      @fragments[idx..] = [] of TextFragment
      invalidate!
      TextBlock.new(tail, @block_format)
    end

    # Appends `other`'s fragments (block-merge on separator removal). The
    # receiver's block format survives, matching Qt's backspace-join.
    def merge_with(other : TextBlock) : Nil
      @fragments.concat(other.fragments)
      normalize!
    end

    # `{fragment index, offset within it}` for `offset`; `{fragments.size, 0}`
    # when `offset == size`.
    private def locate(offset : Int32) : {Int32, Int32}
      acc = 0
      @fragments.each_with_index do |f, i|
        return {i, offset - acc} if offset < acc + f.size
        acc += f.size
      end
      {@fragments.size, 0}
    end

    # Ensures a fragment boundary at `offset`; returns the index of the
    # fragment starting there (== `fragments.size` when `offset == size`).
    private def split_fragment_at(offset : Int32) : Int32
      fi, local = locate(offset)
      return fi if local == 0
      f = @fragments[fi]
      right = f.text[local..]
      f.text = f.text[0, local]
      @fragments.insert(fi + 1, TextFragment.new(right, f.format))
      fi + 1
    end

    private def normalize! : Nil
      invalidate!
      @fragments.reject!(&.text.empty?)
      i = 0
      while i < @fragments.size - 1
        a = @fragments[i]
        b = @fragments[i + 1]
        if a.format.same_appearance?(b.format)
          a.text += b.text
          @fragments.delete_at(i + 1)
        else
          i += 1
        end
      end
    end

    private def invalidate! : Nil
      @text_cache = nil
      @size_cache = nil
      @render_runs_cache = nil
    end
  end
end
