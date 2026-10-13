module Crysterm
  # A detached, formatted slice of a document (Qt `QTextDocumentFragment`):
  # one or more blocks whose boundaries represent block separators. The unit
  # of rich copy/paste and of undo snapshots for removals.
  #
  # Fragments own their blocks; ranges are snapshotted into fresh blocks and
  # re-inserted as *copies*, so a fragment held by the undo stack cannot be
  # corrupted by later document edits.
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

    # The text, block separators as `'\n'` — and, as it reads, a table row
    # whose cells wrap as its display lines (`TextTable.display_lines`),
    # where a document's positions take such a row as one line. What a copy
    # gives a plain-text clipboard.
    def to_plain_text : String
      String.build do |io|
        @blocks.each_with_index do |b, i|
          io << '\n' if i > 0
          io << (b.block_format.table_format ? TextTable.display_text(b.text) : b.text)
        end
      end
    end
  end
end
