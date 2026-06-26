module Crysterm
  class Widget
    module Graph
      # Shared text-overlay helpers for the Canvas-backed graph widgets
      # (`LineChart`, `Donut`, `Map`). These graphs draw their plot/pixels on a
      # `Graph::Canvas` child, then stamp crisp terminal text — titles, axis
      # labels, markers, readouts — directly onto `screen.lines` on top. This
      # module centralizes that stamping plus a small per-color attr memoizer.
      #
      # Including types are `Widget` subclasses, so `screen`, `style` and `sattr`
      # are available.
      module TextOverlay
        # Memoized cell attrs, keyed on *both* the requested color and the
        # current `style.bg`, so a background change doesn't keep serving a stale
        # attr captured at first use.
        @attr_cache = {} of Tuple(Int32, Int32?) => Int64

        # Returns (and caches) the packed cell attr for *color* on the widget's
        # current background.
        private def overlay_attr(color : Int32) : Int64
          bg = style.bg
          @attr_cache[{color, bg}] ||= sattr(style, color, bg)
        end

        # Writes *text* starting at absolute cell (x, y), clipped to the
        # half-open column range `[lo, hi)` so labels never bleed past their
        # region.
        private def put_text(x : Int32, y : Int32, text : String, attr : Int64,
                             lo : Int32, hi : Int32) : Nil
          line = screen.lines[y]?
          return unless line
          text.each_char_with_index do |ch, i|
            cx = x + i
            next if cx < lo || cx >= hi
            if cell = line[cx]?
              cell.char = ch
              cell.attr = attr
            end
          end
          line.dirty = true
        end

        # Writes a single glyph *ch* at absolute cell (x, y), clipped to the
        # half-open column range `[lo, hi)`.
        private def put_cell(x : Int32, y : Int32, ch : Char, attr : Int64,
                             lo : Int32, hi : Int32) : Nil
          return if x < lo || x >= hi
          line = screen.lines[y]?
          return unless line
          if cell = line[x]?
            cell.char = ch
            cell.attr = attr
            line.dirty = true
          end
        end
      end
    end
  end
end
