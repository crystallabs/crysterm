module Crysterm
  # Base for document-level structures (Qt `QTextObject`): things that group
  # blocks or fragments and belong to exactly one `TextDocument` — frames,
  # tables (via `TextFrame`) and lists (via `TextBlockGroup`, Phase 4).
  abstract class TextObject
    getter document : TextDocument

    def initialize(@document : TextDocument)
    end
  end

  # A frame of the document (Qt `QTextFrame`). Phase 1 uses only the root
  # frame, which owns the block list; child frames and `TextTable <
  # TextFrame` arrive in Phase 4 (TEXTEDIT.md §2).
  #
  # A document always contains at least one (possibly empty) block — the Qt
  # invariant that makes cursor math total.
  class TextFrame < TextObject
    getter blocks : Array(TextBlock)
    property frame_format : TextFrameFormat

    def initialize(document : TextDocument, @frame_format : TextFrameFormat = TextFrameFormat.default)
      super(document)
      @blocks = [TextBlock.new]
    end
  end
end
