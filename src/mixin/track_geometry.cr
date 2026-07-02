module Crysterm
  module Mixin
    # Pointer→track geometry for the linear track widgets that map a mouse
    # position along a horizontal or vertical `@orientation` track onto a value:
    # `Widget::Slider` and `Widget::ProgressBar`. Both carried byte-identical
    # axis-extraction code (with the vertical axis flipped so the track fills
    # bottom→top).
    #
    # Kept out of `Mixin::RangedValue` because `ProgressBar` maps onto a 0..100
    # percentage rather than a bounded value and is not a `RangedValue`; kept off
    # `Widget::AbstractSlider` so `ProgressBar` (a plain `Widget::Input`) can
    # share it too. `Widget::ScrollBar` keeps its own extraction: its stepper
    # buttons carve a cell off each end of the track, so it needs the full inner
    # extent to locate the trough before it can seek.
    module TrackGeometry
      # Main-axis pointer offset (cells from the low-value end of the track) and
      # the track span (the number of cells the value maps across — the inner
      # extent minus one) for mouse event *e*. With `invert: true` the vertical
      # axis is flipped so the low end sits at the *bottom*, matching a
      # `Slider`/`ProgressBar` that fills bottom→top.
      protected def pointer_offset(e, invert : Bool = false) : {Int32, Int32}
        if @orientation.horizontal?
          {e.x - aleft - ileft, awidth - iwidth - 1}
        else
          span = aheight - iheight - 1
          pos = e.y - atop - itop
          {invert ? span - pos : pos, span}
        end
      end
    end
  end
end
