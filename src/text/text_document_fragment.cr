module Crysterm
  # A detached, formatted slice of a document (Qt `QTextDocumentFragment`):
  # one or more blocks whose boundaries represent block separators. This is
  # the unit of rich copy/paste and of undo snapshots for removals.
  #
  # Fragments own their blocks: `TextDocument` snapshots ranges into fresh
  # blocks and re-inserts *copies*, so a fragment held by the undo stack can't
  # be corrupted by later document edits.
  class TextDocumentFragment
    getter blocks : Array(TextBlock)

    def initialize(@blocks : Array(TextBlock))
      raise ArgumentError.new("TextDocumentFragment requires at least one block") if @blocks.empty?
    end

    # Builds a fragment from plain text, splitting on `'\n'`.
    def self.from_plain_text(
      text : String,
      format : TextCharFormat = TextCharFormat.default,
      block_format : TextBlockFormat = TextBlockFormat.default,
    ) : TextDocumentFragment
      new(text.split('\n').map { |l| TextBlock.new(l, format, block_format) })
    end

    # Length in document coordinates: block sizes plus one per separator.
    def size : Int32
      @blocks.sum(0, &.size) + @blocks.size - 1
    end

    def empty? : Bool
      size == 0
    end

    def to_plain_text : String
      @blocks.join('\n', &.text)
    end
  end
end
