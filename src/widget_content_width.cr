module Crysterm
  class Widget
    # Widget-side forwarders to the pure `Crysterm::Unicode` measuring layer
    # (src/unicode.cr), supplying this widget's `#full_unicode?` mode. Kept on
    # `Widget` because they are the ergonomic hook layout/subclass code reaches
    # for; the logic itself carries no widget state.

    # Width, in terminal COLUMNS, of `text`'s visible content. SGR sequences are
    # stripped (they occupy no columns); whitespace is preserved. With
    # `#full_unicode?` this is grapheme / East-Asian width (`Unicode`), otherwise
    # the codepoint count (legacy behavior).
    #
    # This is the single width hook layout should use; a raw `.size` miscounts
    # wide / combining characters.
    @[AlwaysInline]
    def str_width(text)
      Unicode.str_width text, full_unicode?
    end

    # Longest *suffix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split).
    @[AlwaysInline]
    def tail_within(text : String, cols : Int) : String
      Unicode.tail_within text, cols, full_unicode?
    end

    # Longest *prefix* of `text` whose display width fits within `cols` columns,
    # measured by grapheme cluster (wide characters count as 2; clusters are
    # never split). The head-side mirror of `#tail_within`, for truncating an
    # over-long line to fit an inner width without splitting a wide glyph.
    @[AlwaysInline]
    def head_within(text : String, cols : Int) : String
      Unicode.head_within text, cols, full_unicode?
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
    # the kept prefix fits within `colwidth` columns. See
    # `Crysterm::Unicode.wrap_cut_index` for the full contract.
    @[AlwaysInline]
    def wrap_cut_index(line : String, colwidth : Int) : Int32
      Unicode.wrap_cut_index line, colwidth, full_unicode?
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
