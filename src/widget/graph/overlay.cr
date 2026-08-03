module Crysterm
  class Widget
    module Graph
      # Text-overlay helpers for the Canvas-backed graph widgets. Such a graph
      # draws its plot/pixels on a `Graph::Canvas` child, then stamps crisp
      # terminal text (titles, axis labels, markers, readouts) directly onto
      # `window.lines` on top. This module carries the per-color attr memoizer
      # and thin `[lo, hi)`-clipped wrappers over the shared `Box` stamp
      # helpers (`stamp_text_run`/`stamp_cell`).
      #
      # Including types must be `Box` subclasses, for those stamp helpers (and
      # `style`/`style_to_attr`).
      module TextOverlay
        # Memoized cell attrs, keyed on *both* the requested color and the current
        # `style.bg`, so a background change doesn't keep serving a stale attr
        # captured at first use.
        @attr_cache = Cache::Bounded(Tuple(Int32, Int32?), Int64).new(Cache::GRAPH_ATTR_CAPACITY)

        # Returns (and caches) the packed cell attr for *color* on the widget's
        # current background.
        private def overlay_attr(color : Int32) : Int64
          bg = style.bg
          @attr_cache.fetch({color, bg}) { style_to_attr(style, color, bg) }
        end

        # Returns (and caches) the packed cell attr for the widget's DEFAULT
        # foreground (`style.fg`) on its current background — the attr used for
        # titles, axis/legend labels and center readouts, drawn every frame.
        # Shares `#overlay_attr`'s `@attr_cache`; the key coalesces a `nil` fg to
        # `-1`, which `Attr.pack_color` already treats identically to an explicit
        # `-1`, so the non-nilable first key slot is satisfied without changing
        # the packed result.
        private def text_attr : Int64
          @attr_cache.fetch({style.fg || -1, style.bg}) { style_to_attr(style, style.fg, style.bg) }
        end

        # Writes *text* starting at absolute cell (x, y), clipped to the
        # half-open column range `[lo, hi)` so labels never bleed past their
        # region.
        private def put_text(x : Int32, y : Int32, text : String, attr : Int64,
                             lo : Int32, hi : Int32) : Nil
          stamp_text_run y, x, text, lo, hi, attr
        end

        # Writes a single glyph *ch* at absolute cell (x, y), clipped to the
        # half-open column range `[lo, hi)`.
        private def put_cell(x : Int32, y : Int32, ch : Char, attr : Int64,
                             lo : Int32, hi : Int32) : Nil
          stamp_cell x, y, ch, attr, lo, hi
        end

        # Centers *text* within the column range `[xi, xl)` on row *y*.
        # No-ops on an empty string.
        private def put_centered(text : String, xi : Int32, xl : Int32, y : Int32, attr : Int64) : Nil
          return if text.empty?
          draw_centered_text y, xi, xl, text, attr
        end
      end

      # Center/radius geometry for the ring-based Canvas graphs: given a `Painter`
      # sized to the device, returns the `{cx, cy, ro}` of the largest
      # physically-round circle that fits, or `nil` when the surface is
      # degenerate. Callers pass their own inner radius to `Painter#fill_ring`, so
      # this stays policy-free — no thickness knob here.
      module RingGeometry
        private def ring_geometry(p : Painter) : Tuple(Float64, Float64, Float64)?
          w = p.width
          h = p.height
          return if w <= 0 || h <= 0
          # True geometric center of the pixel span (`0..w-1`): `(w-1)/2`, not
          # `w//2`, which sits half a pixel low-and-right and skews the ring.
          cx = (w - 1) / 2.0
          cy = (h - 1) / 2.0
          # Largest physically-round radius that fits (vertical extent is scaled
          # by pixel_aspect), with a small margin.
          aspect = p.pixel_aspect
          ro = Math.min(w / 2.0, (h / 2.0) / (aspect <= 0 ? 1.0 : aspect)) * 0.92
          return if ro <= 1
          {cx, cy, ro}
        end
      end
    end
  end
end
