module Crysterm
  class Widget
    # Namespace for data-graphing widgets.
    module Graph
      # Interior-coordinate helper for Canvas-based graph widgets (`Donut`,
      # `Map`, `LineChart`) that draw text overlays inside their content area.
      # Mixed into `Box` subclasses.
      module InteriorCoords
        # The interior content rectangle `{xi, xl, yi, yl}` for the current frame,
        # inset by both padding *and* border (the base `with_inner_coords` insets
        # by border only), or `nil` when the widget isn't positioned yet.
        private def interior_coords : Tuple(Int32, Int32, Int32, Int32)?
          lp = @lpos || return
          content_edges lp
        end
      end

      # Shared scaffolding for the block-glyph bar charts (`Bar`, `StackedBar`):
      # the bar-capacity arithmetic, the repaint-on-render hook, and the per-row
      # tagged-content builder. Including types are `Box` subclasses that declare
      # `@bar_width`/`@bar_spacing` (`Int32`) and a private `#build_content`.
      module BarChart
        # Bumped by `values=` and every decoration setter of the including chart,
        # so `#render` can tell when the plotted inputs changed. Together with the
        # interior size it keys the built-content cache below.
        @data_version = 0

        # The last built tagged-content string and the `{cols, rows, version}` key
        # it was built for. When nothing affecting the plot changed since the last
        # frame, `#render` reuses the string instead of rebuilding it.
        @content_cache : String?
        @content_cache_key : Tuple(Int32, Int32, Int32, {String?, Glyphs::Tier, UInt64})?

        # Invalidate the built-content cache.
        protected def bump_data_version : Nil
          @data_version &+= 1
        end

        # A getter plus a setter that also bumps the content-cache version, so a
        # decoration change invalidates the per-frame build cache.
        macro chart_prop(name, type)
          getter {{ name.id }} : {{ type }}

          def {{ name.id }}=(value : {{ type }})
            @{{ name.id }} = value
            bump_data_version
            # A decoration change alters the built content; `mark_dirty` both
            # registers damage and schedules a frame, so the chart actually
            # repaints instead of waiting for an unrelated render.
            mark_dirty
            value
          end
        end

        # How many bars fit across `cols` columns at the current width/spacing.
        private def bar_capacity(cols : Int32) : Int32
          unit = @bar_width + @bar_spacing
          return 0 if unit <= 0 || cols <= 0
          # The last bar needs no trailing spacing, hence the `+ bar_spacing`.
          (cols + @bar_spacing) // unit
        end

        def render(with_children = true)
          # `glyph_key(style)` covers the fill-ramp inputs `build_content`
          # resolves (CSS `glyphs:`, effective tier, `Glyphs.generation`), so a
          # ramp change rebuilds instead of serving the stale cached content.
          key = {awidth - ihorizontal, aheight - ivertical, @data_version, glyph_key(style)}
          content =
            if @content_cache_key == key && (cached = @content_cache)
              cached
            else
              @content_cache_key = key
              @content_cache = build_content
            end
          self.content = content
          super
        end

        # Writes one plot row of tagged content into *io*: each of the `n` bars
        # contributes `bar_width` copies of its `{glyph, color}` (yielded for bar
        # `i`), separated by `bar_spacing` blank columns. A blank glyph carries no
        # color so coalesced color runs stay tight.
        #
        # Streams straight into the caller's builder so `#build_content` composes
        # the whole widget in one `String.build`: no per-row scratch `String`, no
        # final `Array#join`, and none of the scratch `Array`s `Scale.tagged_row`
        # materializes. Output is byte-identical to `tagged_row`'s.
        private def plot_row(io : IO, n : Int32, & : Int32 -> {Char, String?}) : Nil
          open_color : String? = nil
          n.times do |i|
            glyph, color = yield i
            cell_color = glyph == ' ' ? nil : color
            @bar_width.times do
              if cell_color != open_color
                io << "{/}" if open_color
                if c = cell_color
                  io << '{' << c << "-fg}"
                end
                open_color = cell_color
              end
              io << glyph
            end
            if i < n - 1
              @bar_spacing.times do
                if open_color
                  io << "{/}"
                  open_color = nil
                end
                io << ' '
              end
            end
          end
          io << "{/}" if open_color
        end

        # Writes one caption row into *io*: each bar's text (yielded for bar `i`),
        # centered within its bar width, followed by the inter-bar spacing (plain,
        # untagged).
        private def field_line(io : IO, n : Int32, &) : Nil
          n.times do |i|
            Scale.center_to(io, yield(i), @bar_width, full_unicode?)
            @bar_spacing.times { io << ' ' } if i < n - 1
          end
        end
      end
    end
  end
end
