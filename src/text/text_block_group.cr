module Crysterm
  # Base for objects that group whole blocks of a document (Qt
  # `QTextBlockGroup`).
  #
  # Unlike Qt — where the group is registered storage the blocks point into —
  # a Crysterm group is a lightweight *view*: membership is decided per block
  # by `#member?`, so groups need no document-side registry, survive undo/redo
  # and clipboard round-trips, and are cheap to re-create at any time.
  abstract class TextBlockGroup < TextObject
    # Whether *block* belongs to this group.
    abstract def member?(block : TextBlock) : Bool

    # The group's blocks, in document order.
    def blocks : Array(TextBlock)
      document.blocks.select { |b| member?(b) }
    end

    def count : Int32
      document.blocks.count { |b| member?(b) }
    end

    def empty? : Bool
      count == 0
    end
  end
end
