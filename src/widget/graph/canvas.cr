require "../box"
require "../media"
require "../../widget_graph_painter"

module Crysterm
  class Widget
    module Graph
      # A backend-agnostic vector drawing surface — crysterm's answer to
      # blessed-contrib's braille `canvas`, but *not* tied to braille.
      #
      # You draw with a `Graph::Painter` (a `QPainter`-style API) inside an
      # `#on_paint` block; the result is rasterized into a `PNGGIF::Bitmap` and
      # displayed through whichever `Widget::Media` backend the terminal was
      # detected to support — Kitty/Sixel/iTerm graphics where available, falling
      # back to sub-cell Unicode glyphs (braille by default), then plain cells.
      # Backend selection reuses `Media.resolve(Content::Painter)`, so the user's
      # `image.backend` / `image.exclude` preferences apply exactly as for images:
      #
      # * `type:` forces a specific backend (e.g. `Media::Type::Glyph`).
      # * `mode:` picks the glyph family when the (resolved) backend is `Glyph`;
      #   the default is **braille** — its 8 visible dots read well for plots.
      # * otherwise the best supported backend is auto-detected.
      #
      # The bitmap is sized to the chosen backend's *native* resolution, so a line
      # is crisp on every backend with no resampling. Drawing is in logical
      # coordinates (see `Painter#set_window`), so the same paint code is
      # resolution-independent across backends.
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
      # ![Canvas screenshot](../../../examples/widget/graph/canvas/canvas-capture5s.apng)
      # <!-- /widget-examples:capture -->
      class Canvas < Box
        # The concrete Media backend that presents the painted bitmap. Built in
        # `#initialize` (after `super`, once the screen is reachable for backend
        # detection), so it is stored nilable but is never `nil` post-construction.
        @device : Media::Base?

        # The Media backend presenting the painted bitmap.
        def device : Media::Base
          @device.not_nil!
        end

        # The glyph family used when the backend resolved to `Media::Glyph`
        # (braille by default). Ignored by the pixel backends.
        getter glyph_mode : Media::Glyph::Mode

        @on_paint : (Painter ->)?

        # Reused frame buffer + its current dimensions (reallocated on resize).
        @bitmap : PNGGIF::Bitmap?
        @bmp_w = 0
        @bmp_h = 0

        def initialize(
          type : Media::Type? = nil,
          @glyph_mode : Media::Glyph::Mode = Media::Glyph::Mode::Braille,
          **box,
        )
          super **box

          # Resolve the backend exactly like an image (honoring the user's
          # explicit type / backend / exclude preferences), then build it as a
          # child that fills our interior and presents each painted frame.
          resolved = type || Media.resolve(Media::Content::Painter, screen?.try &.tput)
          # Stretch to our *content* area, not `"100%"`: a string dimension is
          # 100% of the parent's full size (border included), which would overrun
          # the border on the right/bottom. Leaving width/height unset with all
          # four offsets at 0 makes the auto-stretch path subtract our insets, so
          # the device exactly fills the interior.
          @device = Media.new(type: resolved, parent: self,
            top: 0, left: 0, right: 0, bottom: 0)
          @device.as?(Media::Glyph).try do |g|
            g.mode = @glyph_mode
            # Canvas content is vector art on a transparent background: key dots
            # on opacity, not luminance, so dark strokes still render and each
            # cell takes its drawn color (no luminance-threshold flicker).
            g.alpha_key = true
          end

          # Paint into the device's bitmap just before our children (the device)
          # render this frame. `PreRender` fires at the top of our own `_render`,
          # ahead of the child render pass.
          on(Crysterm::Event::PreRender) { paint_frame }
        end

        # Registers the drawing callback, invoked with a `Painter` each render.
        def on_paint(&block : Painter ->) : Nil
          @on_paint = block
        end

        # Requests a repaint + redraw (the paint callback re-runs next frame).
        def refresh : Nil
          request_render
        end

        # Paints the current frame into the backend's bitmap at its native
        # resolution. Runs from our `PreRender`, so the device child then renders
        # the fresh frame.
        private def paint_frame : Nil
          cols = awidth - iwidth
          rows = aheight - iheight
          return if cols <= 0 || rows <= 0

          dev = device
          w, h = dev.native_resolution(cols, rows)
          return if w <= 0 || h <= 0

          bmp = @bitmap
          if bmp.nil? || @bmp_w != w || @bmp_h != h
            bmp = @bitmap = Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(0, 0, 0, 0) } }
            @bmp_w, @bmp_h = w, h
          end

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
