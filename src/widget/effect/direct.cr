require "../box"
require "./animated"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # Shared machinery for "direct" effects — those that paint their interior
      # straight into the screen's cell buffer as packed `Int64` attrs (each fg a
      # direct `0xRRGGBB` value), bypassing the `content` → tag-parse → SGR →
      # re-parse pipeline entirely.
      #
      # That pipeline is a *content-change* path: `_parse_tags` reslices the
      # remaining string on every tag (O(n²)), so driving it every frame for a
      # fully-tagged full-screen field is catastrophic — a single 80×24 plasma
      # frame copies ~100 MB and parses for ~800 ms, which freezes the render
      # fiber (and with it the input loop, so mouse bytes leak to the terminal).
      # A direct effect instead computes a glyph and a `0xRRGGBB` color per cell
      # and writes the packed attr in place, with no per-cell `String` at all.
      #
      # An including widget is a `Box` and must define:
      #
      # * `resize(w, h)` — (re)allocate per-area state when the *w*×*h* interior
      #   size changes. Called from `render` before any `cell`.
      # * `advance(w, h)` — step the simulation one frame (state only — no
      #   painting, no strings). Called from `step`, i.e. once per frame.
      # * `cell(x, y, w, h) : {Char, Int32}` — the glyph and fg color (a packed
      #   `0xRRGGBB`, or `-1` to keep the widget's default fg) for interior cell
      #   `{x, y}`. Called once per cell per frame; must not allocate.
      #
      # Like the other effects it drives its own animation (`#start`/`#stop`), and
      # `#step` (state only) is public so several effects can share one external
      # clock — the shared `screen.render` then paints them all.
      module Direct
        include Animated

        # Interior size seen at the last paint, so `#step` can advance the
        # simulation at the right size without needing the screen.
        @cols = 0
        @rows = 0

        # Advance the simulation one frame (state only). Public so the effect can
        # be driven from an external clock instead of its own fiber.
        def step
          advance @cols, @rows
        end

        # Position via the normal `Box` render (borders, background, docking, and
        # `@lpos`), then overwrite the interior cells directly from `#cell`.
        def render(with_children = true)
          super
          paint
        end

        # Paint the current simulation state into the screen's cell buffer.
        private def paint
          return unless lpos = @lpos
          lines = screen.lines

          # Same border + padding inset the content-draw loop applies, so we paint
          # exactly the interior region.
          xi, xl = lpos.xi, lpos.xl
          yi, yl = lpos.yi, lpos.yl
          if (b = style.border) && b.any?
            xi += b.left
            xl -= b.right
            yi += b.top
            yl -= b.bottom
          end
          p = style.padding
          xi += p.left
          xl -= p.right
          yi += p.top
          yl -= p.bottom

          w = xl - xi
          h = yl - yi
          return if w <= 0 || h <= 0
          if w != @cols || h != @rows
            @cols, @rows = w, h
            resize w, h
          end

          # Default attr carries the widget's bg/flags; only the fg varies per cell.
          da = sattr style
          flags = Attr.flags da
          bgf = Attr.bg da
          deff = Attr.fg da

          (0...h).each do |ry|
            line = lines[yi + ry]?
            next unless line
            (0...w).each do |rx|
              c = line[xi + rx]?
              next unless c
              ch, color = cell rx, ry, w, h
              fgf = color < 0 ? deff : Attr.pack_color(color)
              a = Attr.pack(flags, fgf, bgf)
              if c.attr != a || c.char != ch
                c.attr = a
                c.char = ch
                line.dirty = true
              end
            end
          end
        end
      end
    end
  end
end
