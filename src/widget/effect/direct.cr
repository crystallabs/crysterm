require "./animated"

module Crysterm
  class Widget
    module Effect
      # Shared machinery for "direct" effects — those that paint their interior
      # straight into the window's cell buffer as packed `Int64` attrs (each fg
      # a direct `0xRRGGBB` value), bypassing the `content` -> tag-parse -> SGR
      # -> re-parse pipeline entirely.
      #
      # That pipeline is a content-change path: `_parse_tags` reslices the
      # remaining string on every tag (O(n²)), so driving it every frame for a
      # fully-tagged full-window field is catastrophic — one 80x24 plasma frame
      # copies ~100 MB and parses for ~800 ms, freezing the render fiber (and the
      # input loop, leaking mouse bytes to the terminal). A direct effect computes
      # a glyph and `0xRRGGBB` per cell and writes the packed attr in place, with
      # no per-cell `String`.
      #
      # An including widget is a `Box` and must define (all sizes are the FULL
      # content interior — unclipped by any scrolled/`overflow: Hidden`
      # ancestor, so a partially visible effect keeps simulating its whole
      # field and scrolling never resets it):
      #
      # * `resize(w, h)` — (re)allocate per-area state when the *w*×*h* interior
      #   size changes. Called from `paint` before any `cell`.
      # * `advance(w, h)` — step the simulation one frame (state only — no
      #   painting, no strings). Called from `step`, i.e. once per frame.
      # * `cell(x, y, w, h) : {Char, Int32}` — the glyph and fg color (a packed
      #   `0xRRGGBB`, or `-1` to keep the widget's default fg) for interior cell
      #   `{x, y}`. Called once per cell per frame; must not allocate.
      #
      # Drives its own animation (`#start`/`#stop`) like the other effects;
      # `#step` (state only) is public so several effects can share one
      # external clock, with a single `window.update` painting them all.
      module Direct
        include Animated

        # Interior size seen at the last paint, so `#step` can advance the
        # simulation at the right size without needing the window.
        @cols = 0
        @rows = 0

        # `style_to_attr` memo for the per-frame paint: the effect repaints
        # every frame with an unchanged style, so the base-attr derivation is
        # skipped until a style setter (or a cascade swap) invalidates it.
        @attr_memo = Style::AttrMemo.new

        # Advance the simulation one frame (state only). Public so the effect can
        # be driven from an external clock instead of its own fiber.
        def step
          advance @cols, @rows
          update # repaint under damage tracking
        end

        # Position via the normal `Box` render (borders, background, docking and
        # `@lpos`), then overwrite the interior cells directly from `#cell`.
        def paint(with_children = true)
          with_content_coords(with_children) do |xi, xl, yi, yl|
            paint xi, xl, yi, yl
          end
        end

        # Paint the current simulation state into the window's cell buffer, given
        # the interior content rectangle from `with_content_coords`.
        private def paint(xi : Int32, xl : Int32, yi : Int32, yl : Int32)
          w = xl - xi
          h = yl - yi
          return if w <= 0 || h <= 0
          lines = window.lines
          # Simulate at the UNCLIPPED content size. An ancestor clip (a scrolled
          # or `overflow: Hidden` container) shrinks the *visible* rect per
          # scroll step; sizing the simulation from it would `resize` — i.e.
          # wipe — the whole state on every step, while also squashing the field
          # into the visible slice. Instead the field stays full-size and the
          # visible cells map into it through `clip_offsets` (hidden top rows
          # from `coords.base`, hidden left columns from the unclipped content
          # origin), matching the `Widget::Terminal#draw` clipping convention.
          full_w, full_h, col_off, row_off = full_field_geometry(xi, ileft, iright, itop, ibottom)
          return if full_w <= 0 || full_h <= 0
          if full_w != @cols || full_h != @rows
            @cols, @rows = full_w, full_h
            resize full_w, full_h
          end

          # Default attr carries the widget's bg/flags; only the fg varies per
          # cell, so `Attr.with_fg` reuses `da`'s flags/bg/Opaque alpha.
          da = @attr_memo.fetch(style)
          deff = Attr.fg da

          # Absolute coords (`yi`/`xi`) can be negative when the widget is
          # partly off the top/left edge. `Row`/`lines` are `Indexable`, so a
          # negative index wraps to the end and would corrupt the bottom/right
          # of the terminal — start each loop past the offscreen band instead.
          (Math.max(0, -yi)...h).each do |ry|
            fy = ry + row_off
            break if fy >= full_h
            line = lines[yi + ry]?
            next unless line
            (Math.max(0, -xi)...w).each do |rx|
              fx = rx + col_off
              break if fx >= full_w
              c = line[xi + rx]?
              next unless c
              ch, color = cell fx, fy, full_w, full_h
              fgf = color < 0 ? deff : Attr.pack_color(color)
              # `Cell#set_if_changed` does the same compare/write/skip, but
              # also treats a grapheme-cluster overlay as differing (so a cell
              # left holding a cluster is correctly overwritten and the
              # cluster/link overlays invalidated), and narrows the dirty range
              # to this column instead of widening it to the whole row.
              c.set_if_changed Attr.with_fg(da, fgf), ch
            end
          end
        end
      end
    end
  end
end
