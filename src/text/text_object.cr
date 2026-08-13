module Crysterm
  # Base for document-level structures (Qt `QTextObject`): things that group
  # blocks or fragments and belong to exactly one `TextDocument`.
  abstract class TextObject
    getter document : TextDocument

    def initialize(@document : TextDocument)
    end
  end

  # Read-only, live view over a block list (`Indexable(TextBlock)`), what
  # `TextDocument#blocks` / `TextFrame#blocks` hand out. Indexing and the whole
  # `Enumerable` surface work as on the `Array` these used to return; what's
  # gone is mutation — `doc.blocks.clear` violated the "a document always has
  # at least one block" invariant that makes cursor math total, and a direct
  # push left the document's memoized block offsets stale. Editing goes
  # through `TextCursor`/`TextDocument`'s editing API; the in-tree editing
  # primitives use the protected `TextDocument#blocks_mut`.
  struct TextBlockView
    include Indexable(TextBlock)

    def initialize(@array : Array(TextBlock))
    end

    def size : Int32
      @array.size
    end

    @[AlwaysInline]
    def unsafe_fetch(index : Int) : TextBlock
      @array.unsafe_fetch(index)
    end

    # Range/segment indexing, as on `Array` (returns a fresh `Array` — safe to
    # hold, since it is not the storage).
    def [](range : Range) : Array(TextBlock)
      @array[range]
    end

    # :ditto:
    def [](start : Int, count : Int) : Array(TextBlock)
      @array[start, count]
    end
  end

  # A frame of the document (Qt `QTextFrame`).
  #
  # The *root* frame owns the document's block list; a document always contains
  # at least one — possibly empty — block, the invariant that makes cursor math
  # total. *Child* frames are lightweight views: membership is carried per
  # block by `TextBlockFormat#frame_formats` — the block's chain of enclosing
  # frame formats, outermost first — where the shared `TextFrameFormat`
  # *instance* is the frame's identity. Undo, block splits and clipboard
  # fragments therefore preserve frame membership with no registry.
  #
  # Deviation from Qt: frames contain whole blocks rather than splitting
  # mid-block, since on a cell grid a frame boundary is a row boundary anyway.
  class TextFrame < TextObject
    # The frame's format. For child frames the *instance* is the frame's
    # identity: every member block's `frame_formats` path contains it — which
    # is why there is no public setter: assigning a fresh format would orphan
    # the view (`#member?` compares by `same?`, so `#blocks` would come back
    # empty) without touching the document. Restyle a frame by rewriting its
    # member blocks' formats through the document's editing API instead
    # (`TextList#format=` is the model).
    getter frame_format : TextFrameFormat
    protected setter frame_format

    # Block storage — non-nil only on the root frame.
    @storage : Array(TextBlock)?

    # Root-frame constructor: owns the document's block list.
    def initialize(document : TextDocument, @frame_format : TextFrameFormat = TextFrameFormat.default)
      super(document)
      @storage = [TextBlock.new]
    end

    # A child-frame *view* over the blocks whose frame path contains
    # *frame_format* (by instance identity). Cheap; re-create at any time.
    def initialize(document : TextDocument, @frame_format : TextFrameFormat, child : Bool)
      super(document)
    end

    def root? : Bool
      !@storage.nil?
    end

    # Whether *block* belongs to this frame (directly or through a nested
    # child frame). The root frame contains every block.
    def member?(block : TextBlock) : Bool
      return true if root?
      !!block.block_format.frame_formats.try(&.any?(&.same?(@frame_format)))
    end

    # The frame's blocks in document order, as a read-only view (see
    # `TextBlockView`) — over the live storage for the root frame, over a
    # fresh selection for a child frame.
    def blocks : TextBlockView
      TextBlockView.new(@storage || document.blocks.select { |b| member?(b) })
    end

    # The root frame's live storage array — the mutable counterpart of
    # `#blocks`, for the document's editing primitives only. Must only be
    # called on the root frame.
    protected def root_storage : Array(TextBlock)
      @storage || raise "root_storage called on a child-frame view"
    end

    # Document position of the frame's first block, or nil for an empty
    # child-frame view (Qt `firstPosition` returns positions *inside* the
    # frame; block granularity makes that the first block's start here).
    def first_position : Int32?
      return 0 if root?
      document.blocks.each_with_index do |b, i|
        return document.block_position(i) if member?(b)
      end
      nil
    end

    # Document position of the last member block's end, or nil when empty.
    def last_position : Int32?
      return document.size if root?
      last = nil
      document.blocks.each_with_index do |b, i|
        last = document.block_position(i) + b.size if member?(b)
      end
      last
    end

    # The frames nested directly under this one, in document order (Qt
    # `childFrames`): the distinct formats that appear immediately after this
    # frame in member blocks' paths (immediately first for the root).
    def child_frames : Array(TextFrame)
      seen = [] of TextFrameFormat
      document.blocks.each do |b|
        path = b.block_format.frame_formats || next
        idx = root? ? 0 : ((path.index(&.same?(@frame_format)) || next) + 1)
        if f = path[idx]?
          seen << f unless seen.any?(&.same?(f))
        end
      end
      seen.map { |f| TextFrame.new(document, f, child: true) }
    end

    # The frame containing this one — the root frame for a top-level child
    # frame, nil for the root itself (Qt `parentFrame`) or for an empty view
    # (no member block to read the path from).
    def parent_frame : TextFrame?
      return if root?
      document.blocks.each do |b|
        path = b.block_format.frame_formats || next
        if i = path.index(&.same?(@frame_format))
          return i == 0 ? document.root_frame : TextFrame.new(document, path[i - 1], child: true)
        end
      end
      nil
    end
  end
end
