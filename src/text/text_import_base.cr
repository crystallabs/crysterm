module Crysterm
  # Shared block-assembly / inline-patch skeleton for the format importers
  # (`TextMarkdown::Importer` and `TextHtml::Importer`). Both walk a foreign
  # AST (markd's CommonMark tree, html5's DOM) into the same `TextBlock` /
  # `TextFragment` / `TextBlockFormat` model, and independently grew an
  # identical inner core: a stack of `TextCharFormat` patches folded into the
  # current inline format, a `@blocks`/`@frags`/`@block_format` block builder,
  # quote-level and list stamping in `start_block`, and pre-rendered
  # table-block adoption. This module holds that common core once; the pieces
  # that genuinely differ between the two importers stay behind small
  # overridable hooks (defaults live here; each importer overrides only what it
  # needs).
  #
  # The two importers still keep their own `walk`/`append_text`/`import_table`
  # front-ends (they speak different node types) and their own divergent
  # `end_block` bodies and importer-local state — see each importer for the
  # pieces that stay local and why.
  module TextImport
    # Included into each format importer's private `Importer` class. Carries
    # the state shared verbatim between both importers; the divergent state
    # (`@pending_margin`'s type differs — a `Bool` in markdown, an `Int32` in
    # html — and every other importer-specific flag) stays declared in the
    # including class.
    module Builder
      # Assembled blocks, in document order.
      @blocks = [] of TextBlock
      # Fragments accumulating for the block currently being built.
      @frags = [] of TextFragment
      # The block format for the block currently being built.
      @block_format : TextBlockFormat = TextBlockFormat.default
      # Inline-format patch stack; entering a `Strong`/`<b>` pushes
      # `bold: true`, and the current format is the fold of the stack over the
      # default, so nesting works for free.
      @patches = [] of TextCharFormat
      # Memoized fold of `@patches` (invalidated to `nil` on push/pop and on
      # any importer-specific inline-state change).
      @fmt : TextCharFormat?
      # Current blockquote nesting depth.
      @quote_depth = 0
      # Open (nested) lists; one shared `TextListFormat` instance per source
      # list — instance identity is list identity.
      @list_stack = [] of TextListFormat
      # List the next `start_block`'s block joins (an item's first block).
      @pending_item : TextListFormat?
      # Whether that pending item is a *checked* checkbox item (rides on the
      # block's `TextBlockFormat#checked` flag; the list format itself is
      # shared).
      @pending_checked = false

      # Pushes an inline-format patch for the duration of the block, clearing
      # the memoized current format on both edges. Byte-identical in both
      # importers.
      private def with_patch(patch : TextCharFormat, &) : Nil
        @patches << patch
        @fmt = nil
        yield
        @patches.pop
        @fmt = nil
      end

      # The current inline format: the fold of the patch stack over the
      # default, plus any importer-specific extra merge (markdown folds in its
      # open `~~` strike toggle; html has none).
      private def current_format : TextCharFormat
        @fmt ||= format_extra_merge(@patches.reduce(TextCharFormat.default) { |acc, p| acc.merge(p) })
      end

      # Hook: an importer-specific merge folded onto the raw patch fold in
      # `current_format`. The default is identity (html); markdown overrides it
      # to fold in its `@strike` state.
      private def format_extra_merge(fmt : TextCharFormat) : TextCharFormat
        fmt
      end

      # The final block list for an importer's `import`: an empty run degrades
      # to a single default block so callers always get at least one block.
      private def finalize_blocks : Array(TextBlock)
        @blocks.empty? ? [TextBlock.new] : @blocks
      end

      # Opens a new block: resets the fragment buffer and composes *bf* with any
      # owed margin, the enclosing quote level, and list membership/indent. The
      # margin step and the pending-item/finish steps are hooks (see below)
      # because the two importers diverge there; the quote stamp, list-format
      # merge, checked flag, and continuation indent are identical and live
      # here.
      private def start_block(bf : TextBlockFormat = TextBlockFormat.default, collapse : Bool = true) : Nil
        @frags = [] of TextFragment
        # Owed spacing → this block's top margin. Hook: markdown's owed margin
        # is a flat `top_margin: 1` (a `Bool`), html's is an accumulated
        # `Int32`, so each importer supplies its own `take_margin`.
        bf = take_margin(bf)
        bf = bf.merge(TextBlockFormat.new(quote_level: @quote_depth)) if @quote_depth > 0
        if li = @pending_item
          # An item's first block is the list item proper. Hook: html donates
          # the `<li>` element's own block styles here (default is identity).
          bf = adopt_pending_item(bf)
          bf = bf.merge(TextBlockFormat.new(list_format: li))
          # Checked task item: flag the block (unchecked stays the default).
          bf = bf.merge(TextBlockFormat.new(checked: true)) if @pending_checked
          @pending_item = nil
          @pending_checked = false
          # Hook: html adopts the `<li>`'s whitespace-collapse flag (default is
          # identity).
          collapse = pending_item_collapse(collapse)
        elsif !@list_stack.empty?
          # A continuation block inside an item: indent to roughly the item
          # text column (nesting + a 2-cell marker approximation).
          bf = bf.merge(TextBlockFormat.new(indent: @list_stack.size * 2))
        end
        @block_format = bf
        # Hook: html records collapse mode and its block-open/virgin flags
        # (default is a no-op; markdown carries no such state).
        after_start_block(collapse)
      end

      # Hook: fold the pending list item's element-level block styles into *bf*
      # before list membership is stamped. Default identity (markdown has no
      # per-item element styles); html overrides to donate `@pending_item_format`.
      private def adopt_pending_item(bf : TextBlockFormat) : TextBlockFormat
        bf
      end

      # Hook: resolve the block's whitespace-collapse mode from the pending
      # item. Default returns *collapse* unchanged (markdown has no collapse
      # concept); html overrides to consume `@pending_item_collapse`.
      private def pending_item_collapse(collapse : Bool) : Bool
        collapse
      end

      # Hook: importer-specific bookkeeping after `@block_format` is set.
      # Default no-op (markdown); html overrides to set its collapse / block-open
      # / block-virgin flags.
      private def after_start_block(collapse : Bool) : Nil
      end

      # Emits the block under construction and resets the builder for the next
      # one. The genuinely-common core of both importers' `end_block`; each
      # importer's `end_block` wraps this with its own divergent logic
      # (markdown's strike reset + `@emitted`; html's block-open guard,
      # virgin-block discard, and trailing-space collapse), which is why the
      # `end_block` method itself stays local to each importer.
      private def commit_block : Nil
        @blocks << TextBlock.new(@frags, @block_format)
        @frags = [] of TextFragment
        @block_format = TextBlockFormat.default
      end

      # Appends a pre-rendered table's blocks, carrying any owed top margin onto
      # the first block and any enclosing quote level onto all of them. The
      # margin step is the per-importer `take_margin` hook (markdown's flat
      # `top_margin: 1` vs html's accumulated `Int32`); the quote-level merge
      # over every block and the concat are identical and live here.
      private def adopt_table_blocks(bs : Array(TextBlock)) : Nil
        bs[0].block_format = take_margin(bs[0].block_format)
        if @quote_depth > 0
          q = TextBlockFormat.new(quote_level: @quote_depth)
          bs.each { |b| b.block_format = b.block_format.merge(q) }
        end
        @blocks.concat(bs)
      end
    end
  end
end
