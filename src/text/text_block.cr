module Crysterm
  # One paragraph of a `TextDocument` (Qt `QTextBlock`): an ordered list of
  # `TextFragment` runs plus a `TextBlockFormat`. Blocks never contain the
  # `'\n'` separator — that lives implicitly between consecutive blocks and
  # counts as one position in document coordinates.
  #
  # Offsets here are block-local codepoint indexes, `0..size`. Mutators keep
  # the fragment list normalized (no empty runs, adjacent same-appearance runs
  # merged), so fragment counts are stable for equality checks in specs and
  # for the renderer.
  #
  # Unlike Qt (where QTextBlock is a lightweight handle into piece-table
  # storage) this is the storage itself; TEXTEDIT.md §2 keeps the API
  # Qt-shaped so the representation can change without breaking callers.
  class TextBlock
    getter fragments : Array(TextFragment)
    property block_format : TextBlockFormat

    # Highlighter scratch state (Qt `userState`): e.g. "still inside a
    # multi-line comment". -1 = unset.
    property user_state : Int32 = -1

    @text_cache : String?

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

    # Length in codepoints (without the trailing block separator).
    def size : Int32
      @fragments.sum(0, &.size)
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

    # Deep copy (fragment list is fresh; strings and formats are immutable and
    # shared). Used to detach undo/clipboard snapshots from live blocks.
    def clone : TextBlock
      TextBlock.new(@fragments.map { |f| TextFragment.new(f.text, f.format) }, @block_format)
    end

    # Format of the character *preceding* `offset` (Qt `QTextCursor#charFormat`
    # semantics: what typing at this position would look like); the first
    # character's format at offset 0, default for an empty block.
    def char_format_at(offset : Int32) : TextCharFormat
      return TextCharFormat.default if @fragments.empty?
      return @fragments.first.format if offset <= 0
      fi, local = locate(offset)
      local == 0 ? @fragments[fi - 1].format : @fragments[fi].format
    end

    # Inserts `str` at `offset`. Without an explicit format, inherits the
    # format at the insertion point (Qt typing behavior).
    def insert(offset : Int32, str : String, format : TextCharFormat? = nil) : Nil
      return if str.empty?
      offset = offset.clamp(0, size)
      format ||= char_format_at(offset)
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

    # Non-destructive copy of the `[from, to)` range as a new block (same
    # block format). Building block for `TextDocumentFragment` snapshots.
    def slice(from : Int32, to : Int32) : TextBlock
      frags = [] of TextFragment
      acc = 0
      @fragments.each do |f|
        fstart = acc
        fend = acc + f.size
        acc = fend
        next if fend <= from
        break if fstart >= to
        s = Math.max(from - fstart, 0)
        e = Math.min(to - fstart, f.size)
        frags << TextFragment.new(f.text[s, e - s], f.format)
      end
      TextBlock.new(frags, @block_format)
    end

    # Applies (or merges, see `TextCharFormat#merge`) `format` over `[from, to)`.
    def apply_char_format(from : Int32, to : Int32, format : TextCharFormat, merge : Bool = false) : Nil
      from = from.clamp(0, size)
      to = to.clamp(0, size)
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
    # to the range. Used for undo snapshots of format changes.
    def format_runs(from : Int32, to : Int32) : Array({Int32, Int32, TextCharFormat})
      runs = [] of {Int32, Int32, TextCharFormat}
      acc = 0
      @fragments.each do |f|
        fstart = acc
        fend = acc + f.size
        acc = fend
        next if fend <= from
        break if fstart >= to
        runs << {Math.max(fstart, from), Math.min(fend, to), f.format}
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

    # Ensures a fragment boundary at `offset`; returns the index of the
    # fragment starting there (== `fragments.size` when `offset == size`).
    private def locate(offset : Int32) : {Int32, Int32}
      acc = 0
      @fragments.each_with_index do |f, i|
        return {i, offset - acc} if offset < acc + f.size
        acc += f.size
      end
      {@fragments.size, 0}
    end

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
    end
  end
end
