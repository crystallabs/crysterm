module Crysterm
  module Mixin
    # Canvas ownership for the radial/vector graph widgets
    # (`Widget::Graph::PieChart`, `HeatMap`, `Donut`, `Map`): they each build a
    # single `Graph::Canvas` child that fills their interior, paint into it from
    # an `#on_paint` callback, and must re-raster that Canvas whenever a data or
    # geometry property changes (the Canvas skips repaint otherwise, under its
    # own `@paint_dirty`).
    #
    # Including types are `Box` subclasses that construct the Canvas via
    # `#build_canvas` in their `#initialize` (after `super`). `LineChart` is not
    # a member: its Canvas is named `plot` and is repositioned every frame inside
    # the chart chrome, so it owns its own lifecycle.
    module CanvasOwner
      # The drawing surface, built in `#initialize` via `#build_canvas`. `canvas`
      # raises if read before construction completes; `canvas?` is the nilable
      # variant.
      getter! canvas : Widget::Graph::Canvas

      # Change-guarded setter that re-rasters the Canvas: an assignment changes
      # what the paint callback draws, so — unlike the plain `property` setter —
      # it must invalidate the Canvas raster and schedule a render. Overrides the
      # generated setter; a matching `getter`/`getter?` stays.
      macro canvas_prop(name, type)
        def {{name.id}}=(v : {{type}}) : {{type}}
          return v if v == @{{name.id}}
          @{{name.id}} = v
          invalidate_canvas
          v
        end
      end

      # Builds the Canvas child that fills our interior (all four offsets `0`,
      # auto-stretched to the content area), registers *block* as its paint
      # callback, and stores it as `#canvas`.
      protected def build_canvas(type : Widget::Media::Type?, glyph_mode : Widget::Media::Glyph::Mode, &block : Widget::Graph::Painter ->) : Widget::Graph::Canvas
        cv = Widget::Graph::Canvas.new parent: self, type: type, glyph_mode: glyph_mode,
          top: 0, left: 0, right: 0, bottom: 0
        cv.on_paint(&block)
        @canvas = cv
      end

      # Marks the Canvas content stale and schedules a render, so a data or
      # geometry change repaints (the Canvas skips otherwise, under its own
      # `@paint_dirty`).
      protected def invalidate_canvas : Nil
        canvas?.try &.invalidate_paint
        request_render
      end
    end
  end
end
