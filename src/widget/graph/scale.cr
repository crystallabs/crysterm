module Crysterm
  class Widget
    # Namespace for data-graphing widgets.
    module Graph
      # Shared helpers for the block-glyph graph widgets (`Bar`, `StackedBar`,
      # `Widget::Gauge`). Render numeric values with Unicode "eighth block"
      # glyphs, giving 8x sub-cell resolution along one axis.
      module Scale
        # Vertical eighth blocks: empty (0) .. full (8), filling *upward*.
        VERTICAL = " ▁▂▃▄▅▆▇█".chars

        # Horizontal eighth blocks: empty (0) .. full (8), filling *rightward*.
        HORIZONTAL = " ▏▎▍▌▋▊▉█".chars

        # Full cell — used where sub-cell resolution isn't needed (e.g. the
        # interior of a stacked segment).
        FULL = '█'

        # Number of filled eighth-cells (`0 .. cells*8`) representing `value` on
        # a `[min, max]` scale that spans `cells` whole character cells.
        def self.eighths(value : Float64, min : Float64, max : Float64, cells : Int32) : Int32
          # A non-finite value (NaN from a `0/0` data point, or Infinity) survives
          # `clamp` — all NaN comparisons are false — and `NaN.round.to_i` raises
          # `OverflowError`, crashing the render. Render it as an empty column.
          return 0 unless value.finite?
          range = max - min
          range = 1.0 if range <= 0.0
          norm = ((value - min) / range).clamp(0.0, 1.0)
          # Defensive: a non-finite min/max can still yield a NaN `norm` above.
          norm = 0.0 if norm.nan?
          (norm * cells * 8).round.to_i
        end

        # Glyph for one *vertical* cell, given the column's total filled eighths
        # and how many whole cells sit below this one.
        def self.vglyph(filled_eighths : Int32, below_cells : Int32) : Char
          VERTICAL[(filled_eighths - below_cells * 8).clamp(0, 8)]
        end

        # Glyph for one *horizontal* cell, given the row's total filled eighths
        # and how many whole cells sit to the left of this one.
        def self.hglyph(filled_eighths : Int32, left_cells : Int32) : Char
          HORIZONTAL[(filled_eighths - left_cells * 8).clamp(0, 8)]
        end

        # `hglyph`/`vglyph` over an arbitrary fill *ramp* (empty → full steps — a
        # CSS `glyphs:` override or a registry sequence). The cell's fill (its
        # eighths, relative to `offset_cells` whole cells before it) maps onto the
        # ramp's steps: a 9-step ramp indexes 1:1 (the classic eighth blocks),
        # other lengths scale proportionally.
        def self.ramp_glyph(ramp : Array(Char), filled_eighths : Int32, offset_cells : Int32) : Char
          eighths = (filled_eighths - offset_cells * 8).clamp(0, 8)
          last = ramp.size - 1
          return ramp[0] if last <= 0
          ramp[(eighths * last / 8.0).round.to_i]
        end

        # Fills `cols` cells of a horizontal bar, starting at slot *at*, with the
        # sub-cell ramp glyphs for `filled_eighths` (as produced by `#eighths`
        # over the same `cols`), tagging each non-blank cell with *tag*.
        #
        # A blank (`' '`) glyph is written with a `nil` color so coalesced color
        # runs in `#tagged_row` stay tight — the convention `Gauge` gets for free
        # by pre-filling its arrays with `' '`/`nil` and skipping blanks. Callers
        # must therefore pre-size `cells`/`colors` (a `Char`/`String?` slot per
        # column); writes past `cells.size` are dropped rather than growing the
        # row, so a mis-sized caller can't widen it into a wrap.
        def self.fill_ramp(cells : Array(Char), colors : Array(String?), ramp : Array(Char),
                           filled_eighths : Int32, tag : String?, at : Int32, cols : Int32) : Nil
          n = cells.size
          cols.times do |c|
            x = at + c
            next if x < 0
            break if x >= n
            glyph = ramp_glyph(ramp, filled_eighths, c)
            cells[x] = glyph
            colors[x] = (glyph == ' ' ? nil : tag)
          end
        end

        # Serializes a single row of `cells` into tagged content, wrapping each
        # run of same-colored cells in `{color-fg}…{/}`. A `nil` color emits the
        # characters as-is (default style). Coalescing runs keeps the produced
        # markup compact. Requires the target widget's `parse_tags?` to be on.
        def self.tagged_row(io : IO, cells : Array(Char), colors : Array(String?)) : Nil
          i = 0
          n = cells.size
          while i < n
            color = colors[i]
            j = i
            while j < n && colors[j] == color
              j += 1
            end
            if color
              io << '{' << color << "-fg}"
            end
            (i...j).each { |k| io << cells[k] }
            io << "{/}" if color
            i = j
          end
        end

        # `#tagged_row` as a `String`, for the callers that build one row at a
        # time (`Gauge`, `GaugeList`) rather than streaming a whole widget into
        # one builder.
        def self.tagged_row(cells : Array(Char), colors : Array(String?)) : String
          String.build { |io| tagged_row io, cells, colors }
        end

        # Centers `text` within a field of `width` cells (truncating if longer),
        # padding with spaces. Returns a new `String`; prefer `#center_to` on the
        # render path.
        def self.center(text : String, width : Int32, full_unicode : Bool = false) : String
          String.build { |io| center_to io, text, width, full_unicode }
        end

        # Writes `text`, centered within a field of `width` cells (truncating if
        # longer), straight to *io* — pads are emitted char-by-char rather than
        # via `" " * n` + concatenation, so a per-frame caption row builds with
        # no intermediate `String`s.
        #
        # When *full_unicode* is true the field is measured and truncated in
        # terminal DISPLAY columns (wide CJK/emoji graphemes count as 2, and
        # graphemes are never split), matching how the plot rows are laid out.
        # Otherwise codepoint sizing (`text.size` / `text[0, width]`) applies.
        def self.center_to(io : IO, text : String, width : Int32, full_unicode : Bool = false) : Nil
          return if width <= 0
          tw = full_unicode ? Unicode.display_width(text) : text.size
          if tw >= width
            if full_unicode
              # Keep the leading `width` columns: drop trailing graphemes once
              # the next one would overflow (never split a grapheme).
              io << text.byte_slice(0, Unicode.leading_byte_len(text, width, true))
            else
              io << text[0, width]
            end
            return
          end
          pad = width - tw
          left = pad // 2
          left.times { io << ' ' }
          io << text
          (pad - left).times { io << ' ' }
        end

        # Overlays `text` onto `cells`/`colors` (parallel arrays serialized by
        # `#tagged_row`), starting at *display column* `at`, and writes it in
        # place. Module-level (not a widget method) because `Gauge`/`GaugeList`
        # share it, so `full_unicode` is passed explicitly rather than read off
        # `Widget#full_unicode?`.
        #
        # Measures/advances by *display columns*, not codepoints: a wide
        # (CJK/emoji) grapheme occupies 2 terminal columns but only 1 array
        # slot, so writing it into a single `Char` slot and advancing by 1
        # would under-consume the row, making the serialized content wider
        # than `cells.size` columns and wrapping the row. Instead, a wide char
        # consumes an extra slot — deleted from both arrays (not blanked:
        # blanking would still serialize to one column too many) — so the
        # arrays shrink but the row keeps exactly its original display width.
        # A wide char that would land in the row's last slot (no continuation
        # slot to delete) stops the overlay rather than corrupt the tail. A
        # zero-width (combining) char is skipped outright: writing it into its
        # own slot would remove a display column it doesn't occupy.
        #
        # Callers overlaying more than one caption onto the same row (e.g. one
        # per stacked segment) must overlay them in *reverse* (right-to-left)
        # order: a wide char's slot deletion shifts every later index, so
        # processing right-to-left keeps not-yet-overlaid positions stable.
        def self.overlay_text(cells : Array(Char), colors : Array(String?), at : Int32, text : String, full_unicode : Bool = false) : Nil
          x = at
          text.each_char do |ch|
            cw = full_unicode ? Unicode.display_width(ch.to_s) : 1
            next if cw == 0
            if x < 0
              x += cw
              next
            end
            break if x >= cells.size
            if cw == 2
              break if x + 1 >= cells.size # no continuation slot to consume
              cells[x] = ch
              colors[x] = nil
              cells.delete_at(x + 1)
              colors.delete_at(x + 1)
            else
              cells[x] = ch
              colors[x] = nil
            end
            x += 1
          end
        end

        # Formats a numeric value compactly: integers lose their `.0`, others
        # are rounded to one decimal. Uses `to_i64` (not `to_i`, which is Int32
        # and raises `OverflowError` on ordinary large data — byte counts,
        # populations, timestamps ≥ 2³¹) when dropping the fractional part.
        def self.fmt(v : Float64) : String
          # A non-finite value (Infinity from a divide-by-zero / `log(0)` in the
          # plotted data, or NaN) has `v == v.round`, so the whole-number branch
          # would call `Infinity.to_i64` — an `OverflowError` that crashes the
          # render. A *finite* whole value beyond Int64 (≥ ~9.22e18) overflows it
          # just the same. Render both as their plain string.
          return v.to_s unless v.finite? && v.abs < 9.2e18
          v == v.round ? v.to_i64.to_s : v.round(1).to_s
        end
      end
    end
  end
end
