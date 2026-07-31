module Crysterm
  # The heading outline of a `TextDocument`: the input both TOC renderers read
  # — the inline `TextToc` frame and the `Widget::TocView` sidebar. Neither owns
  # it, so a document's contents list is the same fact however it is displayed,
  # and is available headless, with no widget mounted.
  #
  # Anchors are *derived* from the heading text rather than stored, so markdown
  # round-trips need no anchor syntax and no extra block-format state. The rules
  # approximate github.com's, which is not documented anywhere — see `.slug`.
  module TextOutline
    # One heading. `block` is an index into `TextDocument#blocks`, valid for the
    # `revision` the outline was taken at; `anchor` is unique within that
    # outline.
    record Entry,
      level : Int32,
      text : String,
      anchor : String,
      block : Int32

    # A github.com-shaped anchor slug: strip, lowercase, drop everything that
    # is neither alphanumeric nor `-`/`_`, and turn each whitespace character
    # into one `-`.
    #
    # Dropping by "not alphanumeric" is Unicode-aware and so removes punctuation
    # *and* emoji in one rule, where the reference implementations
    # (`../textual/src/textual/_slug.py`) enumerate ASCII punctuation plus a
    # hand-listed set of emoji ranges. Letters outside ASCII are kept, matching
    # the raw `id` github.com emits; percent-encoding is left to whoever writes
    # a URL — `MarkdownExporter#encode_url` does it for link destinations, and
    # doing it here would double-encode.
    #
    # Whitespace maps one-for-one, so `"a  b"` slugs to `"a--b"`, as on
    # github.com. A heading of pure punctuation slugs to `""`.
    def self.slug(text : String) : String
      String.build do |io|
        text.strip.each_char do |c|
          if c.whitespace?
            io << '-'
          elsif c == '-' || c == '_'
            io << c
          elsif c.alphanumeric?
            io << c.downcase
          end
        end
      end
    end

    # Generates slugs unique within one document: a repeat of an already-issued
    # slug gets `-1`, `-2`, … appended, as github.com does for repeated
    # headings.
    #
    # Uniqueness is inherent to a single outline pass rather than something
    # callers reproduce, which is what keeps anchors stable: `TextDocument#outline`
    # runs one `Slugger` over the whole document and stores the result, so no
    # later lookup ever re-slugs. (Textual's `goto_anchor` re-slugs the entire
    # document on every jump, which is both O(n) per lookup and a second place
    # for the rules to drift.)
    class Slugger
      def initialize
        @used = Hash(String, Int32).new(0)
      end

      def slug(text : String) : String
        base = TextOutline.slug(text)
        n = @used[base]
        @used[base] = n + 1
        n == 0 ? base : "#{base}-#{n}"
      end
    end
  end

  class TextDocument
    @outline_cache : Array(TextOutline::Entry)?
    @outline_revision : Int64 = -1

    # The document's headings in document order, with unique derived anchors.
    #
    # Memoized against `#revision`, which is documented as bumped by every
    # mutation, so equal readings guarantee identical content *and* formatting
    # — the same cache-key contract `TextList`'s member memo relies on.
    #
    # Blocks inside a `TextToc` frame are excluded: a generated contents list
    # is derived data, and indexing it would make every refresh grow it.
    def outline : Array(TextOutline::Entry)
      cached = @outline_cache
      return cached if cached && @outline_revision == revision
      @outline_revision = revision
      @outline_cache = build_outline
    end

    private def build_outline : Array(TextOutline::Entry)
      slugger = TextOutline::Slugger.new
      res = [] of TextOutline::Entry
      blocks.each_with_index do |b, i|
        bf = b.block_format
        next unless bf.heading?
        next if bf.frame_formats.try(&.any?(TextTocFormat))
        text = b.text
        res << TextOutline::Entry.new(bf.heading_level, text, slugger.slug(text), i)
      end
      res
    end
  end
end
