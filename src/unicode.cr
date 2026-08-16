module Crysterm
  # Unicode display-width support for terminal cells — the base implementation
  # lives in the tput shard (`Tput::Unicode`): terminal column-width is a
  # terminal-domain concern shared by anything driving a tty, not toolkit
  # logic. The alias keeps every `Crysterm::Unicode.…` call site working.
  #
  # (The `@cluster`-layout pinning spec for `width(String::Grapheme)` /
  # `cluster_size` lives with the module's specs.)
  #
  # A real `alias` (not a constant assignment), so nested constants
  # (`Unicode::WIDE`) resolve through it too.
  alias Unicode = ::Tput::Unicode
end

# The SGR-aware column-measuring layer, added by Crysterm to the module its
# `Crysterm::Unicode` alias points at (Crysterm owns the SGR grammar the
# base shard has no notion of). Pure functions over text and a
# `full_unicode` mode flag — they carry no widget state, which is why they
# live here rather than on `Widget` (`Widget#str_width` & co. are one-line
# forwarders that supply `#full_unicode?`).
class Tput
  module Unicode
    extend self

    # Width, in terminal COLUMNS, of *text*'s visible content. SGR sequences are
    # stripped (they occupy no columns); whitespace is preserved. With
    # *full_unicode* this is grapheme / East-Asian width, otherwise the codepoint
    # count (legacy behavior).
    #
    # This is the single width hook layout should use; a raw `.size` miscounts
    # wide / combining characters.
    def str_width(text, full_unicode : Bool) : Int32
      # Most strings have no SGR; the cheap `includes?` byte scan skips the regex
      # (and the String it builds) unless an ESC is actually present.
      text = text.gsub ::Crysterm::SGR::REGEX, "" if text.includes? '\e'
      full_unicode ? display_width(text) : text.size
    end

    # Longest *suffix* of *text* whose display width fits within *cols* columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split).
    def tail_within(text : String, cols : Int, full_unicode : Bool) : String
      return "" if cols <= 0
      return text if str_width(text, full_unicode) <= cols
      text.byte_slice trailing_byte_len(text, cols.to_i, true)
    end

    # Longest *prefix* of *text* whose display width fits within *cols* columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split). The head-side mirror of `.tail_within`, for truncating an
    # over-long line to fit an inner width without splitting a wide glyph.
    def head_within(text : String, cols : Int, full_unicode : Bool) : String
      return "" if cols <= 0
      return text if str_width(text, full_unicode) <= cols
      text.byte_slice 0, leading_byte_len(text, cols.to_i, true)
    end

    # Character index in *line* (which may contain inline SGR) at which to cut so
    # the kept prefix fits within *colwidth* columns. SGR sequences consume no
    # columns — strictly those `Crysterm::SGR.run_len` recognizes, so an `\e` that
    # opens no valid run counts as visible text, exactly as `.str_width` counts
    # it. Under *full_unicode* widths are grapheme/East-Asian and clusters are
    # never split; otherwise one column per codepoint (legacy).
    # Returns `line.size` when the whole line fits; a single grapheme wider than
    # *colwidth* is kept whole rather than looping forever.
    def wrap_cut_index(line : String, colwidth : Int, full_unicode : Bool) : Int32
      sgr = ::Crysterm::SGR
      total = 0
      # Single forward walk via `Char::Reader`; a char-by-char scan would be O(n²),
      # since `String#[](Int)` is O(index) for multibyte content. `cp` tracks the
      # codepoint index of the reader's current char (what callers slice by);
      # `reader.pos` is the byte offset, used for grapheme segmentation (and for
      # the byte-level SGR scan, which needs no decoding at all).
      bytesize = line.bytesize
      bytes = line.to_slice
      reader = Char::Reader.new line
      cp = 0
      while reader.pos < bytesize
        if len = sgr.run_len(bytes, reader.pos, bytesize)
          # Zero-width: skip the run whole. It is pure ASCII, so its byte length
          # is also its codepoint length, and `pos=` reseeks in O(1).
          reader.pos = reader.pos + len
          cp += len
          next
        end

        # Contiguous run of visible text up to the next SGR run (or end of line).
        # A non-conforming `\e` does not end the run: it is visible text, and the
        # width metrics below treat it as `.str_width` would (0 columns under
        # *full_unicode*, since it is a control character; 1 codepoint in the
        # legacy count).
        if full_unicode
          # Grapheme/East-Asian widths: segment the run's bytes as clusters. This
          # path must measure the whole run — presentation selectors like VS16/VS15
          # can flip a cluster's width, so a bounded window is not provably
          # byte-identical.
          run_byte_start = reader.pos
          run_cp_start = cp
          while reader.pos < bytesize && sgr.run_len(bytes, reader.pos, bytesize).nil?
            reader.next_char; cp += 1
          end
          pos = run_cp_start
          line.byte_slice(run_byte_start, reader.pos - run_byte_start).each_grapheme do |g|
            gs = g.to_s
            w = width gs
            # Cut before this cluster once we already have content placed.
            return pos if total + w > colwidth && total > 0
            total += w
            pos += gs.size
          end
        else
          # One column per visible codepoint (legacy). Walk only until the column
          # budget is met rather than to the end of the run. Before reading the
          # char at codepoint index `c`, `cp == c`; after advancing, `cp == c + 1`.
          while reader.pos < bytesize && sgr.run_len(bytes, reader.pos, bytesize).nil?
            reader.next_char
            cp += 1
            total += 1
            return cp if total == colwidth
          end
        end
      end
      cp
    end
  end
end
