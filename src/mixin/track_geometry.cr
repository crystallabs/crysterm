module Crysterm
  module Mixin
    # Pointer→track geometry for linear track widgets that map a mouse position
    # along a horizontal or vertical `@orientation` track onto a value.
    #
    # The including type must provide `@orientation`, `@lpos`, and the
    # `aleft`/`atop`/`awidth`/`aheight` plus inner-extent accessors.
    module TrackGeometry
      # Main-axis pointer offset (cells from the low-value end of the track) and
      # the track span (the number of cells the value maps across — the inner
      # extent minus one) for mouse event *e*. With `invert: true` the vertical
      # axis is flipped so the low end sits at the *bottom*, matching a track
      # that fills bottom→top.
      protected def pointer_offset(e, invert : Bool = false) : {Int32, Int32}
        # Resolve against the *painted* origin (`@lpos`), not the layout coords:
        # inside a scrolled container the two differ by the scroll base, and
        # `e.x`/`e.y` are painted coords. Falls back before the first render.
        lp = @lpos
        if @orientation.horizontal?
          origin_x = lp ? lp.xi : aleft
          {e.x - origin_x - ileft, awidth - ihorizontal - 1}
        else
          span = aheight - ivertical - 1
          origin_y = lp ? lp.yi : atop
          pos = e.y - origin_y - itop
          {invert ? span - pos : pos, span}
        end
      end
    end
  end
end
