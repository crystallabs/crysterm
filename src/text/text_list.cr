module Crysterm
  # A decorated list of blocks (Qt `QTextList`): the blocks of a document whose
  # `TextBlockFormat#list_format` is this list's `TextListFormat` *instance* —
  # instance identity is list identity. Items are numbered in document order;
  # the marker (bullet glyph or number) renders left of each item, indented
  # `(format.indent - 1) * 2` cells per nesting level.
  #
  # All mutations go through the document's undoable block-format API.
  class TextList < TextBlockGroup
    getter format : TextListFormat

    def initialize(document : TextDocument, @format : TextListFormat = TextListFormat.new)
      super(document)
    end

    def member?(block : TextBlock) : Bool
      block.block_format.list_format.same?(@format)
    end

    # Memoized member list for `#item_number`/`#item`, both of which were
    # O(document blocks) per call (hot when rendering every marker of a long
    # list). Keyed on `document.revision` — documented as bumped by *every*
    # mutation (content, format, undo/redo, replace), so equal readings
    # guarantee identical membership — plus the `@format` instance, since
    # `#format=` swaps list identity without necessarily touching a block
    # (e.g. on an empty list).
    @members_cache : Array(TextBlock)?
    @members_revision : Int64 = -1
    @members_format : TextListFormat?

    private def members : Array(TextBlock)
      cached = @members_cache
      if cached && @members_revision == document.revision && @format.same?(@members_format)
        return cached
      end
      @members_revision = document.revision
      @members_format = @format
      @members_cache = blocks
    end

    # 0-based item index of *block* within the list (Qt `itemNumber`), -1
    # when it is not a member.
    def item_number(block : TextBlock) : Int32
      members.index(&.same?(block)) || -1
    end

    # The 0-based *index*-th item, or nil.
    def item(index : Int32) : TextBlock?
      # Negative indexes are "no such item", as in the scan this replaced —
      # `Array#[]?` alone would resolve them from the end.
      return if index < 0
      members[index]?
    end

    # The rendered marker of *block* (`"• "`, `"3. "`, …), or nil when not a
    # member.
    def marker_text(block : TextBlock, tier : Glyphs::Tier = Glyphs::Tier::Unicode) : String?
      n = item_number(block)
      n >= 0 ? @format.marker(n, tier, block.block_format.checked?) : nil
    end

    # Makes *block* a member (undoable). Its other block-format properties are
    # kept; membership in another list is replaced.
    def add(block : TextBlock) : Nil
      set_block_membership(block, @format)
    end

    # Removes *block* from the list (undoable); its text and other formatting
    # stay.
    def remove(block : TextBlock) : Nil
      return unless member?(block)
      set_block_membership(block, nil)
    end

    # Removes the item at the 0-based *index*, if any (Qt `removeItem(int)`);
    # out of range is a no-op.
    def remove_item(index : Int32) : Nil
      item(index).try { |b| remove(b) }
    end

    # Replaces the list's format for every member (undoable). Membership
    # identity moves to *fmt*'s instance: this view follows it, but other views
    # over the old instance see an empty list, and an undo restores the old
    # instance rather than this view's — so re-derive views after an undo.
    def format=(fmt : TextListFormat) : TextListFormat
      old = @format
      @format = fmt
      document.begin_edit_block
      begin
        document.blocks.each_with_index do |b, i|
          next unless b.block_format.list_format.same?(old)
          pos = document.block_position(i)
          document.apply_block_format(pos, pos, b.block_format.with_list_format(fmt))
        end
      ensure
        document.end_edit_block
      end
      fmt
    end

    private def set_block_membership(block : TextBlock, lf : TextListFormat?) : Nil
      bi = document.blocks.index(&.same?(block))
      return unless bi
      pos = document.block_position(bi)
      document.apply_block_format(pos, pos, block.block_format.with_list_format(lf))
    end
  end
end
