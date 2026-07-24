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
        # Resolve against the *painted* origin (`painted_origin`, i.e. `@lpos`
        # with a pre-render fallback), not the layout coords: inside a scrolled
        # container the two differ by the scroll base, and `e.x`/`e.y` are
        # painted coords.
        if @orientation.horizontal?
          {e.x - painted_origin[0] - ileft, awidth - ihorizontal - 1}
        else
          span = aheight - ivertical - 1
          pos = e.y - painted_origin[1] - itop
          {invert ? span - pos : pos, span}
        end
      end
    end
  end
end
