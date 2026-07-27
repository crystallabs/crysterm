module Crysterm
  class Widget
    # Width, in terminal COLUMNS, of `text`'s visible content. SGR sequences are
    # stripped (they occupy no columns); whitespace is preserved. With
    # `#full_unicode?` this is grapheme / East-Asian width (`Unicode`), otherwise
    # the codepoint count (legacy behavior).
    #
    # This is the single width hook layout should use; a raw `.size` miscounts
    # wide / combining characters.
    def str_width(text)
      # Most strings have no SGR; the cheap `includes?` byte scan skips the regex
      # (and the String it builds) unless an ESC is actually present.
      text = text.gsub SGR_REGEX, "" if text.includes? '\e'
      full_unicode? ? Unicode.display_width(text) : text.size
    end

    # Longest *suffix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split).
    def tail_within(text : String, cols : Int) : String
      return "" if cols <= 0
      return text if str_width(text) <= cols
      text.byte_slice Unicode.trailing_byte_len(text, cols.to_i, true)
    end

    # Longest *prefix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split). The head-side mirror of `#tail_within`, for truncating an
    # over-long line to fit an inner width without splitting a wide glyph.
    def head_within(text : String, cols : Int) : String
      return "" if cols <= 0
      return text if str_width(text) <= cols
      text.byte_slice 0, Unicode.leading_byte_len(text, cols.to_i, true)
    end

    # Grapheme-aware backspace; implementation in `Unicode.chop_grapheme`.
    def chop_grapheme(text : String) : String
      Unicode.chop_grapheme text
    end

    # Whether *base* begins a multi-codepoint grapheme cluster, given successor
    # *nxt* — i.e. whether `#extend_grapheme` would assemble anything beyond
    # `base` alone. Cheap pre-check letting the renderer skip cluster assembly for
    # the common lone-codepoint cell. Mirrors `#extend_grapheme`'s start
    # conditions exactly.
    def needs_cluster?(base : Char, nxt : Char?) : Bool
      Unicode.needs_cluster? base, nxt
    end

    # Assembles the grapheme cluster beginning with `base` (codepoint at
    # `content[ci - 1]`) by consuming following extending codepoints from
    # `content` starting at `ci`: combining marks, ZWJ (and the codepoint it
    # joins), variation selectors, emoji skin-tone modifiers, and a second
    # regional indicator for flags. Returns `{cluster, new_ci}`.
    #
    # A pragmatic subset of UAX-#29 covering cases that occur in terminal text;
    # `content` is anything indexable by codepoint (`#[]?` returning `Char?`).
    def extend_grapheme(content, ci : Int32, base : Char) : Tuple(String, Int32)
      Unicode.extend_grapheme content, ci, base
    end

    # (The SGR scanning primitives `run_start`/`run_len`/`each_run` and the
    # grammar itself live in `Crysterm::SGR` — src/sgr.cr.)

    # Character index in `line` (which may contain inline SGR) at which to cut so
    # the kept prefix fits within `colwidth` columns. SGR sequences consume no
    # columns — strictly those `SGR.run_len` recognizes, so an `\e` that opens
    # no valid run counts as visible text, exactly as `#str_width` counts it.
    # Under `#full_unicode?` widths are grapheme/East-Asian and
    # clusters are never split; otherwise one column per codepoint (legacy).
    # Returns `line.size` when the whole line fits; a single grapheme wider than
    # `colwidth` is kept whole rather than looping forever.
    def wrap_cut_index(line : String, colwidth : Int) : Int32
      full = full_unicode?
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
        if len = SGR.run_len(bytes, reader.pos, bytesize)
          # Zero-width: skip the run whole. It is pure ASCII, so its byte length
          # is also its codepoint length, and `pos=` reseeks in O(1).
          reader.pos = reader.pos + len
          cp += len
          next
        end

        # Contiguous run of visible text up to the next SGR run (or end of line).
        # A non-conforming `\e` does not end the run: it is visible text, and the
        # width metrics below treat it as `#str_width` would (0 columns under
        # `full_unicode?`, since it is a control character; 1 codepoint in the
        # legacy count).
        if full
          # Grapheme/East-Asian widths: segment the run's bytes as clusters. This
          # path must measure the whole run — presentation selectors like VS16/VS15
          # can flip a cluster's width, so a bounded window is not provably
          # byte-identical.
          run_byte_start = reader.pos
          run_cp_start = cp
          while reader.pos < bytesize && SGR.run_len(bytes, reader.pos, bytesize).nil?
            reader.next_char; cp += 1
          end
          pos = run_cp_start
          line.byte_slice(run_byte_start, reader.pos - run_byte_start).each_grapheme do |g|
            gs = g.to_s
            w = Unicode.width gs
            # Cut before this cluster once we already have content placed.
            return pos if total + w > colwidth && total > 0
            total += w
            pos += gs.size
          end
        else
          # One column per visible codepoint (legacy). Walk only until the column
          # budget is met rather than to the end of the run. Before reading the
          # char at codepoint index `c`, `cp == c`; after advancing, `cp == c + 1`.
          while reader.pos < bytesize && SGR.run_len(bytes, reader.pos, bytesize).nil?
            reader.next_char
            cp += 1
            total += 1
            return cp if total == colwidth
          end
        end
      end
      cp
    end

    # Slices *line* to the display-column window `[from_col, from_col + width)`,
    # preserving SGR colors: the active escape state at the cut is re-emitted as
    # a prefix, and escapes past the window carried as a zero-width suffix, so a
    # clipped line still starts and ends in the right color. Column math is
    # grapheme/East-Asian-aware via `#wrap_cut_index`. With `from_col == 0` this
    # reduces to the original no-wrap truncation. Used for horizontal scrolling
    # of non-wrapped content.
    protected def _hslice(line : String, from_col : Int32, width : Int32) : String
      # Fast path for the common SGR-free line: plain column-window substring,
      # no escape scanning.
      unless line.includes? '\e'
        from = from_col > 0 ? wrap_cut_index(line, from_col) : 0
        rest = line[from..]
        return rest[0...wrap_cut_index(rest, width)]
      end

      if from_col > 0
        cut = wrap_cut_index(line, from_col)
        # Byte end of the `line[0...cut]` prefix the SGR-active scan covers.
        cut_b = line.char_index_to_byte_index(cut) || line.bytesize
        rest = line[cut..]
      else
        cut_b = 0
        rest = line
      end
      keep = wrap_cut_index(rest, width)
      keep_b = rest.char_index_to_byte_index(keep) || rest.bytesize

      line_bytes = line.to_slice
      rest_bytes = rest.to_slice
      # One builder instead of two `scan(Regex)` calls (each an `Array(MatchData)`
      # plus a `String` per match plus a join) and two more substrings: the runs
      # are copied straight out of the source bytes.
      String.build(cut_b + rest.bytesize) do |io|
        # SGR active at the cut, re-emitted as a prefix.
        SGR.each_run(line, 0, cut_b) { |st, len| io.write line_bytes[st, len] }
        io.write rest_bytes[0, keep_b]
        # Escapes past the window, carried as a zero-width suffix.
        SGR.each_run(rest, keep_b, rest.bytesize) { |st, len| io.write rest_bytes[st, len] }
      end
    end
  end
end
