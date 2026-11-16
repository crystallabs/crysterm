# The shard's definitions must load before this file: the `codepoint_width`
# redefinition below only wins as the later definition.
require "tput"

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

    # Control characters an editor's document may hold and a cell cannot
    # show: C0 but TAB, LF and CR, DEL, and C1.
    CONTROL_CHARS = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/

    # *text* with every `CONTROL_CHARS` character replaced by a visible one
    # of one column (`.control_picture`), so a column still names the
    # character it did. Returns *text* itself when it holds none.
    def picture_controls(text : String) : String
      # 0xC2 leads every C1 control's UTF-8 form.
      return text unless text.to_slice.any? { |b| (b < 0x20 && b != 0x09 && b != 0x0a && b != 0x0d) || b == 0x7f || b == 0xc2 }
      text.gsub(CONTROL_CHARS) { |m| control_picture m[0] }
    end

    # Whether *char* is one of `CONTROL_CHARS`.
    def pictured_control?(char : Char) : Bool
      cp = char.ord
      (cp < 0x20 && cp != 0x09 && cp != 0x0a && cp != 0x0d) || (0x7f <= cp <= 0x9f)
    end

    # The one-column stand-in for control character *char*: its Unicode
    # control picture (U+2400…U+241F, U+2421 for DEL), U+FFFD for a C1
    # control, which has none.
    def control_picture(char : Char) : Char
      cp = char.ord
      if cp < 0x20
        (0x2400 + cp).chr
      elsif cp == 0x7f
        '\u2421'
      else
        '\uFFFD'
      end
    end

    # Columns occupied by a single codepoint (redefines the shard method with a
    # wider fast path): combining marks begin at U+0300 and every other
    # zero-width or wide codepoint sits higher still, so every printable
    # codepoint below U+0300 — ASCII, Latin-1, Latin Extended — is exactly 1
    # column, with no category search. Called per cell per frame by the render
    # and draw loops. Must stay behavior-identical to `Tput::Unicode`'s
    # definition for codepoints ≥ U+0300.
    def codepoint_width(char : Char) : Int32
      cp = char.ord
      return 1 if 0x20 <= cp <= 0x7E
      # C0/C1 controls and NUL — the whole of Unicode category Cc.
      return 0 if cp <= 0x1F || (0x7F <= cp <= 0x9F)
      return 1 if cp < 0x300
      if cp < 0x1100
        # Below the first WIDE range: never wide, so skip that binary search.
        return 0 if char.mark? # combining marks
        return 0 if zero_width? cp
        return 1
      end
      # `wide?` first: CJK/emoji cells resolve on one binary search instead of
      # paying the `mark?` category search (a miss for them) before it. The only
      # zero-width marks *inside* WIDE blocks are U+302A..302F and U+3099..309A —
      # excluded here so they keep width 0 (order elsewhere doesn't matter:
      # every other mark/zero-width codepoint is outside the WIDE ranges).
      unless (0x302A <= cp <= 0x302F) || (0x3099 <= cp <= 0x309A)
        return 2 if wide? cp
      end
      return 0 if char.mark? # combining marks
      return 0 if zero_width? cp
      1
    end

    # Width, in terminal COLUMNS, of *text*'s visible content. SGR sequences are
    # stripped (they occupy no columns); whitespace is preserved. With
    # *full_unicode* this is grapheme / East-Asian width, otherwise the codepoint
    # count (legacy behavior).
    #
    # This is the single width hook layout should use; a raw `.size` miscounts
    # wide / combining characters.
    def str_width(text, full_unicode : Bool) : Int32
      # Most strings have no SGR; the cheap byte scan settles those at once.
      bytes = text.to_slice
      esc = bytes.index(0x1B_u8)
      return full_unicode ? display_width(text) : text.size unless esc

      # One byte scan: the runs' total length, and whether everything outside
      # them is printable ASCII (one column and one codepoint a byte in
      # either metric).
      n = bytes.size
      run_bytes = 0
      plain = bytes[0, esc].all? { |b| 0x20_u8 <= b <= 0x7E_u8 }
      stray = false
      i = esc
      while i < n
        if len = ::Crysterm::SGR.run_len(bytes, i, n)
          run_bytes += len
          i += len
        else
          b = bytes.unsafe_fetch(i)
          if b == 0x1B_u8
            # An `\e` opening no run: left to `REGEX`, whose `\d` is wider.
            stray = true
            break
          end
          plain = false unless 0x20_u8 <= b <= 0x7E_u8
          i += 1
        end
      end
      if stray
        text = text.gsub ::Crysterm::SGR::REGEX, ""
        return full_unicode ? display_width(text) : text.size
      end
      return n - run_bytes if plain
      # A run is pure ASCII, so its bytes are also its codepoints.
      return text.size - run_bytes unless full_unicode

      # Clusters are measured over the text with its runs removed, so one
      # that a run splits still counts once.
      stripped = String.new(n - run_bytes) do |buffer|
        kept = 0
        i = 0
        while i < n
          if len = ::Crysterm::SGR.run_len(bytes, i, n)
            i += len
          else
            buffer[kept] = bytes.unsafe_fetch(i)
            kept += 1
            i += 1
          end
        end
        {kept, 0}
      end
      display_width stripped
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
          #
          # The run's end is found by byte search for the next `\e` that opens
          # an SGR run (UTF-8 continuation bytes are never 0x1B), not by
          # decoding every char: a cut is wanted for each row of a long line,
          # and decoding the whole rest of it each time made wrapping one long
          # line quadratic in its length.
          run_byte_start = reader.pos
          run_end = bytesize
          search = run_byte_start + 1
          while search < bytesize && (esc = bytes.index(0x1B_u8, search))
            if sgr.run_len(bytes, esc, bytesize)
              run_end = esc
              break
            end
            search = esc + 1
          end
          pos = cp
          line.byte_slice(run_byte_start, run_end - run_byte_start).each_grapheme do |g|
            gs = g.to_s
            w = width gs
            # Cut before this cluster once we already have content placed.
            return pos if total + w > colwidth && total > 0
            total += w
            pos += gs.size
          end
          reader.pos = run_end
          cp = pos
        else
          # One column per visible codepoint (legacy). Walk only until the column
          # budget is met rather than to the end of the run. Before reading the
          # char at codepoint index `c`, `cp == c`; after advancing, `cp == c + 1`.
          while reader.pos < bytesize && sgr.run_len(bytes, reader.pos, bytesize).nil?
            reader.next_char
            cp += 1
            total += 1
            return cp if total >= colwidth
          end
        end
      end
      cp
    end
  end
end
