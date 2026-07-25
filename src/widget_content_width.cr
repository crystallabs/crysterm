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

    # Returns `text` with its last grapheme cluster removed (e.g. a base +
    # combining mark, or a wide emoji, comes off as one unit) — grapheme-aware
    # backspace. Empty in, empty out.
    def chop_grapheme(text : String) : String
      return text if text.empty?
      # Track the final cluster's byte length while scanning (no per-cluster
      # allocation) and slice it off the end.
      last_bytes = 0
      text.each_grapheme { |g| last_bytes = g.bytesize }
      text.byte_slice 0, text.bytesize - last_bytes
    end

    # Whether *base* begins a multi-codepoint grapheme cluster, given successor
    # *nxt* — i.e. whether `#extend_grapheme` would assemble anything beyond
    # `base` alone. Cheap pre-check letting the renderer skip cluster assembly for
    # the common lone-codepoint cell. Mirrors `#extend_grapheme`'s start
    # conditions exactly.
    def needs_cluster?(base : Char, nxt : Char?) : Bool
      # Fast rejection for the dominant plain-text path: every cluster-relevant
      # `base` *and* `nxt` is ≥ U+0300 — combining marks (the lowest cluster
      # extender) begin there, and ZWJ/variation selectors/skin tones/regional
      # indicators sit higher still. Two integer compares replace the `mark?`
      # Unicode-category binary searches per ASCII/Latin cell.
      #
      # The threshold on `nxt` must be U+0300, NOT U+200D (ZWJ): a base such as
      # `'e'` followed by a combining mark (e.g. U+0301, NFD "é") has
      # `nxt.ord == 0x301` — above 0x300 but far below 0x200D — so a 0x200D cut
      # fast-rejects that common base+mark cluster and the mark renders detached.
      return false if base.ord < 0x300 && (nxt.nil? || nxt.ord < 0x300)
      return true if base.mark?                        # a leading combining mark (zero-width; merges back)
      return true if Unicode.regional_indicator?(base) # regional indicator (flag pair)
      return false unless nxt
      # A following combining mark, ZWJ, variation selector, or skin-tone modifier
      # extends the cluster.
      Unicode.grapheme_extender?(nxt)
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
      g = String::Builder.new
      g << base

      # A flag is a pair of regional indicators.
      if Unicode.regional_indicator?(base)
        if (c = content[ci]?) && Unicode.regional_indicator?(c)
          g << c
          ci += 1
        end
        return {g.to_s, ci}
      end

      while c = content[ci]?
        cp = c.ord
        if Unicode.grapheme_extender?(c)
          g << c
          ci += 1
          # A ZWJ also pulls in the codepoint it joins (e.g. the next emoji).
          if cp == 0x200D && (c2 = content[ci]?)
            g << c2
            ci += 1
          end
        else
          break
        end
      end

      {g.to_s, ci}
    end

    # Given a codepoint index `mi` in `line` pointing at an `'m'`, returns the
    # codepoint index of the `\e` that opens the SGR sequence it terminates, or
    # `nil` if the bytes back to the `\e` aren't a valid `\e[[\d;]*m` run. `line[k]`
    # is O(k) for multibyte content, but the run is short and this only fires on a
    # candidate `'m'` within the ~10-char word-wrap lookback window.
    def sgr_run_start(line : String, mi : Int32) : Int32?
      k = mi - 1
      while k >= 0
        c = line[k]
        case c
        when '\e'
          # Need the `[` immediately after the `\e` (i.e. at `k + 1`).
          return k if k + 1 < mi && line[k + 1] == '['
          return
        when '[', ';', '0'..'9'
          k -= 1
        else
          return
        end
      end
      nil
    end

    # Character index in `line` (which may contain inline SGR) at which to cut so
    # the kept prefix fits within `colwidth` columns. SGR sequences consume no
    # columns. Under `#full_unicode?` widths are grapheme/East-Asian and
    # clusters are never split; otherwise one column per codepoint (legacy).
    # Returns `line.size` when the whole line fits; a single grapheme wider than
    # `colwidth` is kept whole rather than looping forever.
    def wrap_cut_index(line : String, colwidth : Int) : Int32
      full = full_unicode?
      total = 0
      # Single forward walk via `Char::Reader`; a char-by-char scan would be O(n²),
      # since `String#[](Int)` is O(index) for multibyte content. `cp` tracks the
      # codepoint index of the reader's current char (what callers slice by);
      # `reader.pos` is the byte offset, used for grapheme segmentation.
      bytesize = line.bytesize
      reader = Char::Reader.new line
      cp = 0
      while reader.pos < bytesize
        if reader.current_char == '\e'
          reader.next_char; cp += 1
          while reader.pos < bytesize && reader.current_char != 'm'
            reader.next_char; cp += 1
          end
          if reader.pos < bytesize # consume the terminating 'm'
            reader.next_char; cp += 1
          end
          next
        end

        # Contiguous run of visible text up to the next SGR (or end of line).
        if full
          # Grapheme/East-Asian widths: segment the run's bytes as clusters. This
          # path must measure the whole run — presentation selectors like VS16/VS15
          # can flip a cluster's width, so a bounded window is not provably
          # byte-identical.
          run_byte_start = reader.pos
          run_cp_start = cp
          while reader.pos < bytesize && reader.current_char != '\e'
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
          while reader.pos < bytesize && reader.current_char != '\e'
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
        each_sgr_run(line, 0, cut_b) { |st, len| io.write line_bytes[st, len] }
        io.write rest_bytes[0, keep_b]
        # Escapes past the window, carried as a zero-width suffix.
        each_sgr_run(rest, keep_b, rest.bytesize) { |st, len| io.write rest_bytes[st, len] }
      end
    end

    # Yields `{byte_start, byte_count}` for each SGR run of *s* lying wholly
    # inside the byte window `[from, to)`, in order — the allocation-free
    # equivalent of `s[from...to].scan(SGR_RE)`. Byte-level scanning is exact
    # here: `\e`, `[` and `m` are ASCII and so can never occur as a byte of a
    # multi-byte codepoint.
    #
    # NOTE the grammar is `/\e\[[^m]*m/` — deliberately reproduced as-is from
    # `#_hslice`'s previous regexes, and **looser** than the module-wide
    # `SGR_REGEX` (`/\e\[[\d;]*m/`) that `#str_width`/`#wrap_cut_index` measure
    # against. A non-SGR CSI sequence (e.g. `\e[2K`) is therefore captured and
    # re-emitted here but not treated as zero-width by the column math. That
    # divergence is pre-existing and is left for a deliberate separate call
    # rather than silently changed by an allocation fix.
    private def each_sgr_run(s : String, from : Int32, to : Int32, & : Int32, Int32 ->) : Nil
      bytes = s.to_slice
      i = from
      while i < to
        if bytes.unsafe_fetch(i) == 0x1b_u8 && i + 1 < to && bytes.unsafe_fetch(i + 1) == 0x5b_u8
          # `[^m]*` cannot match `m`, so the run ends at the first `m` — and
          # since it *can* match `\e`, a `\e[` with no following `m` in the
          # window yields nothing and the scan simply resumes one byte on, just
          # as `String#scan` retries from the next position.
          j = i + 2
          while j < to && bytes.unsafe_fetch(j) != 0x6d_u8 # 'm'
            j += 1
          end
          if j < to
            yield i, j - i + 1
            i = j + 1
            next
          end
        end
        i += 1
      end
    end
  end
end
