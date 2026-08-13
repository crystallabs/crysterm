module Crysterm
  # How a `TextToc` renders its entries.
  struct TocOptions
    # Whether entries are numbered.
    enum Numbering
      # Bullet markers (`TextListFormat::Style::Disc`).
      None
      # Decimal markers, restarting per nesting group.
      Ordered
    end

    # Heading levels to include; a document whose only `#` is its title wants
    # `min_level: 2`. The shallowest included level becomes the list's top
    # nesting level.
    getter min_level : Int32
    getter max_level : Int32

    # Whether entries carry anchors.
    #
    # Semantically "entries link to their headings", which the two renderers
    # read differently: an inline `TextToc` puts `anchor_href` on the fragments,
    # so they render in the theme link color and take part in link focus and
    # click activation, and exports them as real markdown links. A
    # `Widget::TocView` navigates on selection regardless, so there this only
    # decides whether entries are *styled* as links.
    getter? links : Bool

    getter numbering : Numbering

    # A heading placed above the entries (e.g. `"Contents"`), rendered at
    # `min_level`. It sits inside the frame, so it never indexes itself.
    getter title : String?

    def initialize(
      *,
      @min_level : Int32 = 1,
      @max_level : Int32 = 6,
      @links : Bool = true,
      @numbering : Numbering = :none,
      @title : String? = nil,
    )
    end

    # The list style entries are marked with.
    def list_style : TextListFormat::Style
      @numbering.ordered? ? TextListFormat::Style::Decimal : TextListFormat::Style::Disc
    end

    def includes?(level : Int32) : Bool
      level >= @min_level && level <= @max_level
    end
  end

  # Frame format of a table of contents (`TextTocFormat < TextFrameFormat`,
  # mirroring `TextTableFormat < TextFrameFormat`). One *instance* per TOC —
  # instance identity is TOC identity, referenced from every generated block's
  # `TextBlockFormat#frame_formats` path.
  class TextTocFormat < TextFrameFormat
    getter options : TocOptions

    def initialize(@options : TocOptions = TocOptions.new, *, margin : Int32 = 0, border : Bool = false)
      super(margin: margin, border: border)
    end
  end

  # A generated table of contents living *inside* the document (`[TOC]`'s
  # destination), as opposed to `Widget::TocView`, which renders the same
  # `TextDocument#outline` beside it.
  #
  # The entries are ordinary blocks — a nested `TextList` whose fragments carry
  # `anchor_href` — so wrapping, selection, mouse hit-testing,
  # `Widget::TextBrowser#links` and markdown export all work with no new
  # machinery. What makes them a TOC is the frame: membership rides on the
  # block format's frame path, so the region survives undo, block splits and
  # clipboard round-trips with no document-side registry (see `TextFrame`).
  #
  # **The contents are derived data and sit outside the undo stack.** `#refresh`
  # rewrites the region without recording an undo command, so `Ctrl+Z` can never
  # step *into* a regenerated TOC and leave it describing a document it no
  # longer matches. `TextCursor#insert_toc` is the exception: creating a TOC is
  # a user edit, and is one undoable step.
  #
  # Refreshing is explicit — `TextDocument#refresh_tocs`, typically bound to a
  # re-render action and run after a load. It is deliberately not automatic: a
  # TOC that grows while the reader is below it shifts every row under it, and
  # a shift the reader did not ask for is worse than a stale contents list.
  class TextToc < TextFrame
    def initialize(document : TextDocument, format : TextTocFormat)
      super(document, format, true)
    end

    def toc_format : TextTocFormat
      @frame_format.as(TextTocFormat)
    end

    def options : TocOptions
      toc_format.options
    end

    # The headings this TOC covers: the document outline filtered by the
    # option's level range. Blocks inside any TOC frame are already excluded by
    # `TextDocument#outline`, so a TOC never indexes itself or another one.
    def entries : Array(TextOutline::Entry)
      opts = options
      document.outline.select { |e| opts.includes?(e.level) }
    end

    # `{first, last}` block indexes of the region, or nil when no block carries
    # this TOC's format.
    #
    # The range spans from the first member to the last, so anything typed
    # *between* generated blocks is absorbed by the next `#refresh` — the
    # region is regenerated wholesale, and hand edits inside it are not
    # preserved.
    def block_range : {Int32, Int32}?
      first = nil
      last = 0
      document.blocks.each_with_index do |b, i|
        next unless member?(b)
        first ||= i
        last = i
      end
      first.try { |f| {f, last} }
    end

    # The blocks this TOC's current entries render as, detached. *base* supplies
    # the surrounding context (frame path, quote level) every generated block
    # inherits.
    def build_blocks(base : TextBlockFormat, theme : TextTheme = TextTheme.default) : Array(TextBlock)
      opts = options
      res = [] of TextBlock

      if title = opts.title
        res << TextBlock.new(title, TextCharFormat.new(fg: theme.heading_color),
          base.merge(TextBlockFormat.new(heading_level: opts.min_level)))
      end

      # One `TextListFormat` instance per open nesting level. Descending again
      # after coming back up pushes a *fresh* instance, so ordered numbering
      # restarts per sibling group the way a hand-written nested list does,
      # while siblings interrupted by a deeper group keep counting.
      stack = [] of TextListFormat
      style = opts.list_style

      entries.each do |e|
        depth = Math.max(0, e.level - opts.min_level)
        stack.pop(stack.size - depth - 1) if stack.size > depth + 1
        while stack.size < depth + 1
          stack << TextListFormat.new(style: style, indent: stack.size + 1)
        end

        fmt =
          if opts.links?
            TextCharFormat.new(fg: theme.link_color, anchor_href: "##{e.anchor}")
          else
            TextCharFormat.default
          end
        res << TextBlock.new(e.text, fmt, base.with_list_format(stack.last))
      end

      # A TOC with nothing to show still occupies one block, so the frame stays
      # non-empty and keeps its place in the document.
      res << TextBlock.new("", TextCharFormat.default, base) if res.empty?
      res
    end

    # Regenerates the region from the current outline, **without recording an
    # undo command**. Returns whether anything changed — an unchanged outline
    # performs no mutation at all, so `TextDocument#revision` is untouched and
    # views do not repaint.
    def refresh(theme : TextTheme = TextTheme.default) : Bool
      first, last = block_range || return false
      bs = document.blocks
      built = build_blocks(TextToc.context_format(bs[first].block_format), theme)
      return false if same_blocks?(bs[first..last], built)
      document.raw_replace_block_run(first, last, built)
      true
    end

    # Removes the region and its blocks (undoable), leaving the surrounding
    # document intact.
    #
    # Which separator goes with it matters: a removal spanning one merges the
    # surrounding blocks and the *first* block's format survives
    # (`TextDocument#remove`). Taking the preceding separator therefore leaves
    # the neighbour's format in place, while taking the following one would
    # leave the TOC's own — and a block still stamped with this frame would
    # keep the now-empty TOC alive.
    def remove : Bool
      first, last = block_range || return false
      bs = document.blocks
      from = document.block_position(first)
      to = document.block_position(last) + bs[last].size
      document.edit do
        if from > 0
          document.remove(from - 1, to - from + 1)
        elsif to < document.size
          # At the document start there is no preceding block to inherit from,
          # so restore the following block's format explicitly.
          after = bs[last + 1].block_format
          document.remove(from, to - from + 1)
          document.apply_block_format(from, from, after)
        else
          # The TOC is the whole document; a document always keeps one block.
          document.remove(from, to - from)
          document.apply_block_format(from, from, TextBlockFormat.default)
        end
      end
      true
    end

    # The context a generated block inherits from the region it replaces:
    # frame path and quote level only. Everything else (list membership,
    # heading level, margins) is regenerated, so a stale title heading or list
    # format from the previous contents cannot leak onto every new entry.
    def self.context_format(src : TextBlockFormat) : TextBlockFormat
      q = src.quote_level
      TextBlockFormat.new(frame_formats: src.frame_formats, quote_level: q > 0 ? q : nil)
    end

    # Whether two block runs are the same content *and* formatting — the test
    # that lets an unchanged refresh mutate nothing. Format equality is by
    # value (`TextBlockFormat`/`TextCharFormat` define `==`), so freshly built
    # list formats compare equal to the instances they replace.
    private def same_blocks?(a : Array(TextBlock), b : Array(TextBlock)) : Bool
      return false unless a.size == b.size
      a.each_with_index do |x, i|
        y = b[i]
        return false unless x.text == y.text && x.block_format == y.block_format
        return false unless x.fragments.size == y.fragments.size
        x.fragments.each_with_index do |f, j|
          g = y.fragments[j]
          return false unless f.text == g.text && f.format == g.format
        end
      end
      true
    end
  end

  class TextDocument
    # Every table of contents in the document, in the order their formats are
    # first seen. Cheap views, re-created at any time (see `TextFrame`).
    def tocs : Array(TextToc)
      seen = [] of TextTocFormat
      blocks.each do |b|
        b.block_format.frame_formats.try &.each do |f|
          seen << f if f.is_a?(TextTocFormat) && !seen.any?(&.same?(f))
        end
      end
      seen.map { |f| TextToc.new(self, f) }
    end

    # Regenerates every table of contents, returning whether any changed.
    #
    # This is the explicit refresh the whole design turns on: call it after a
    # load, after `#set_markdown`, and from whatever action the application
    # gives the reader. Nothing calls it on its own.
    def refresh_tocs(theme : TextTheme = TextTheme.default) : Bool
      changed = false
      tocs.each { |toc| changed = true if toc.refresh(theme) }
      changed
    end

    # Swaps the blocks at index range `[first, last]` for *new_blocks*,
    # adjusting cursors and emitting `Event::ContentsChanged` but recording **no
    # undo command** — the `raw_*` contract (hence the name and `protected`,
    # like its siblings): generated regions (`TextToc`) live outside the undo
    # stack by design and are rebuilt by a different object than the one that
    # owns the primitives.
    #
    # *new_blocks* must be non-empty and is adopted, not copied.
    protected def raw_replace_block_run(first : Int32, last : Int32, new_blocks : Array(TextBlock)) : Nil
      raise ArgumentError.new("raw_replace_block_run requires at least one block") if new_blocks.empty?
      bs = blocks_mut
      first = first.clamp(0, bs.size - 1)
      last = last.clamp(first, bs.size - 1)
      pos = block_position(first)
      removed = block_position(last) + bs[last].size - pos
      added = new_blocks.sum(0, &.size) + new_blocks.size - 1
      bs[first..last] = new_blocks
      finish_edit(pos, removed, added)
    end
  end

  class TextCursor
    # Inserts a table of contents at the cursor and fills it from the current
    # outline (Qt has no analogue; mirrors `#insert_list`/`#insert_frame`).
    #
    # One undo step — unlike later `TextToc#refresh` calls, which are derived
    # data and record nothing. The TOC takes the current block when it is empty,
    # otherwise it starts a new one.
    def insert_toc(options : TocOptions = TocOptions.new, theme : TextTheme = TextTheme.default) : TextToc
      fmt = TextTocFormat.new(options)
      base = block.block_format
      path = (base.frame_formats || [] of TextFrameFormat) + [fmt]
      toc = TextToc.new(@document, fmt)
      built = toc.build_blocks(TextToc.context_format(base).with_frame_formats(path), theme)

      @document.edit do
        # Mid-block, break first so the TOC starts on a row of its own; the
        # cursor lands at the start of the tail block, as Qt's `insertBlock`
        # leaves it.
        insert_block unless at_block_start?
        # An empty block at its start is free real estate — the TOC's last block
        # becomes it. Otherwise the run needs its own trailing separator, or its
        # last entry would merge into the content that follows.
        text = built.join('\n', &.text)
        text += '\n' unless block.empty?
        start = @position
        # Insert the text first and stamp formats after: `insert_text` splits on
        # `'\n'` into blocks the same way typing would, which sidesteps the
        # block-format adoption rules a multi-block fragment insertion carries.
        @document.insert_text(start, text)
        pos = start
        built.each do |b|
          @document.apply_block_format(pos, pos, b.block_format)
          off = 0
          b.fragments.each do |f|
            @document.apply_char_format(pos + off, pos + off + f.size, f.format)
            off += f.size
          end
          pos += b.size + 1
        end
      end
      toc
    end

    # The table of contents containing the cursor, or nil.
    def current_toc : TextToc?
      f = block.block_format.frame_formats.try(&.find(&.is_a?(TextTocFormat)))
      f.is_a?(TextTocFormat) ? TextToc.new(@document, f) : nil
    end
  end
end
