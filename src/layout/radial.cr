require "../layout"

module Crysterm
  class Layout
    # Radial (circular) layout — Android `ConstraintLayout`'s circular
    # positioning, or the ring arrangement of graph/menu tools. Children are
    # placed at equal angular steps around the largest ellipse that keeps each
    # child fully inside the interior, each centered on its ring point; the
    # interior's center hosts nothing, so a radial menu can put its hub there
    # with a separate `Manual`-placed child or a nested container.
    #
    # `#start_angle` (degrees) sets where the first child sits: 0° points right
    # (+x), angles grow clockwise in screen coordinates (y grows downward), and
    # the default of -90° puts the first child at 12 o'clock. A hidden child
    # gives its slot back (`#vacant?`), tightening the ring — matching the
    # packing engines.
    #
    # Children keep their own size; the engine only moves them. NOTE: like
    # `UniformGrid`, children should carry an explicit `width`/`height` — a
    # nil-size (`auto`) child's `awidth`/`aheight` report the *stretched*
    # full-interior size, which collapses its ring radius to zero and parks it
    # over the whole interior.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Radial screenshot](../../tests/layout/radial/radial.5s.apng)
    # <!-- /widget-examples:capture -->
    class Radial < Layout
      # Angle of the first child, in degrees (0° = right, clockwise positive,
      # default -90° = top). Change-guarded so a real change repaints the
      # container — animate a spinning ring by just advancing this.
      layout_property start_angle, Float64

      def initialize(@start_angle : Float64 = -90.0)
      end

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        # Slot count first: the angular step divides the circle among the
        # children that occupy a slot this frame, so a hidden child tightens
        # the ring instead of leaving a gap.
        n = 0
        each_occupying(container) { |_el| n += 1 }
        step = n > 0 ? 360.0 / n : 0.0

        iw = interior.width
        ih = interior.height
        i = 0
        each_arrangeable container do |el|
          # Mirror the Flow engines' hidden-child path: consume the render
          # index (z-order bookkeeping), nil the subtree's `lpos`, take no slot.
          if vacant? el
            bump_index el
            skip_subtree el
            next
          end
          bump_index el

          # Per-child ring semi-axes: shrink by half the child's own size so
          # the child, centered on its ring point, never leaves the interior.
          w = clamped_size el.awidth, iw
          h = clamped_size el.aheight, ih
          rad = (start_angle + step * i) * Math::PI / 180.0
          x = ((iw - w) / 2.0 * (1.0 + Math.cos(rad))).round.to_i32
          y = ((ih - h) / 2.0 * (1.0 + Math.sin(rad))).round.to_i32
          # Position only — children keep their own size (`nil` = unmanaged),
          # so a percent/auto size stays live.
          place_child el, x, y, nil, nil
          render_or_defer el
          i += 1
        end
      end
    end
  end
end
