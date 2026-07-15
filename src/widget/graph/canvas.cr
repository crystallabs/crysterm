require "../box"
require "../media"
require "../../widget_graph_painter"

module Crysterm
  class Widget
    module Graph
      # A backend-agnostic vector drawing surface.
      #
      # Draw with a `Graph::Painter` (a `QPainter`-style API) inside an
      # `#on_paint` block; the result is rasterized into a `PNGGIF::Bitmap` and
      # displayed through whichever `Widget::Media` backend the terminal
      # supports — Kitty/Sixel/iTerm graphics where available, falling back to
      # sub-cell Unicode glyphs (braille by default), then plain cells. The
      # user's `image.backend` / `image.exclude` preferences apply as for images:
      #
      # * `type:` forces a specific backend (e.g. `Media::Type::Glyph`, or a
      #   pinned variant like `Media::Type::GlyphBraille`).
      # * `mode:` picks the glyph family when the (resolved) backend is a `Glyph`;
      #   the default is **braille** — its 8 visible dots read well for plots.
      # * otherwise the best supported backend is auto-detected.
      #
      # The bitmap is sized to the chosen backend's *native* resolution, so a line
      # is crisp on every backend with no resampling. Drawing is in logical
      # coordinates, so the same paint code is resolution-independent across
      # backends.
      #
      # ```
      # cv = Widget::Graph::Canvas.new parent: s, width: 40, height: 12,
      #   style: Style.new(border: true)
      # cv.on_paint do |p|
      #   p.set_window 0, -1, 6.28, 2 # logical: x in 0..2π, y in -1..1
      #   p.pen = 0x40E0D0
      #   pts = (0..120).map { |i| {i * 6.28 / 120, Math.sin(i * 6.28 / 120)} }
      #   p.draw_polyline pts
      # end
      # cv.refresh
      # ```
      #
      # <!-- widget-examples:capture v1 -->
      # ![Canvas screenshot](../../../tests/widget/graph/canvas/canvas.5s.apng)
      # <!-- /widget-examples:capture -->
      class Canvas < Box
        # The Media backend presenting the painted bitmap. Nilable only until
        # `#initialize` can reach the window for backend detection; never `nil`
        # post-construction.
        getter! device : Media::Base

        # The glyph family used when the backend resolved to `Media::Glyph`
        # (braille by default). Ignored by the pixel backends.
        getter glyph_mode : Media::Glyph::Mode

        @on_paint : (Painter ->)?

        # Reused frame buffer + its current dimensions (reallocated on resize).
        @bitmap : PNGGIF::Bitmap?
        @bmp_w = 0
        @bmp_h = 0

        # Whether the painted content is stale and must be re-rasterized. While
        # clear, painting skips the whole raster→resample→encode pipeline, so a
        # static chart landing in an unrelated render doesn't repaint. Any state
        # a paint callback reads must therefore invalidate this on change.
        @paint_dirty = true

        def initialize(
          type : Media::Type? = nil,
          @glyph_mode : Media::Glyph::Mode = Media::Glyph::Mode::Braille,
          **box,
        )
          super **box

          # Resolve the backend like an image — going through `Media.resolve`
          # applies the `media.backend` pin and `media.exclude` uniformly, so the
          # painter path can't drift from images/video.
          resolved = type || Media.resolve(Media::Content::Painter, window?.try &.tput)
          # Stretch to the *content* area, not `"100%"`: a string dimension is
          # 100% of the parent's full size, border included, which would overrun
          # the border. Unset width/height with all four offsets at 0 makes
          # auto-stretch subtract the insets instead.
          @device = Media.new(type: resolved, parent: self,
            top: 0, left: 0, right: 0, bottom: 0)
          @device.as?(Media::Glyph).try do |g|
            g.mode = @glyph_mode
            # Vector art on a transparent background: key dots on opacity, not
            # luminance, so dark strokes still render without flicker.
            g.alpha_key = true
          end

          # Paint into the device's bitmap just before children render this
          # frame; `PreRender` fires ahead of the child render pass.
          on(Crysterm::Event::PreRender) { paint_frame }
        end

        # Registers the drawing callback, invoked with a `Painter` each render.
        def on_paint(&block : Painter ->) : Nil
          @on_paint = block
          @paint_dirty = true
        end

        # Requests a repaint + redraw (the paint callback re-runs next frame).
        def refresh : Nil
          @paint_dirty = true
          request_render
        end

        # Marks the painted content stale so the next render re-runs the paint
        # callback, *without* itself scheduling a render. For a container that
        # owns this Canvas and issues its own `request_render`: it only needs the
        # Canvas to repaint on that same frame.
        def invalidate_paint : Nil
          @paint_dirty = true
        end

        # Paints the current frame into the backend's bitmap at its native
        # resolution.
        private def paint_frame : Nil
          cols = awidth - ihorizontal
          rows = aheight - ivertical
          return if cols <= 0 || rows <= 0

          dev = device
          w, h = dev.native_resolution(cols, rows)
          return if w <= 0 || h <= 0

          bmp = @bitmap
          if bmp.nil? || @bmp_w != w || @bmp_h != h
            # First paint or a resize: (re)allocate and force a repaint (the new
            # buffer starts cleared, and the backend must be re-fed at the new size).
            bmp = @bitmap = Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(0, 0, 0, 0) } }
            @bmp_w, @bmp_h = w, h
            @paint_dirty = true
          end

          # Nothing changed since the last paint: the backend already holds this
          # exact bitmap, so skip re-rasterizing, re-sampling and re-encoding —
          # and skip `dev.bitmap=`, which would drop its sample cache.
          return unless @paint_dirty
          @paint_dirty = false

          painter = Painter.new(bmp)
          painter.pixel_aspect = dev.native_pixel_aspect
          painter.clear
          @on_paint.try &.call(painter)

          dev.bitmap = bmp
        end
      end
    end
  end
end
