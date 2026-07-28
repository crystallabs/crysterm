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
      # that fills bottom→top. Clip-aware via `#pointer_track`.
      protected def pointer_offset(e, invert : Bool = false) : {Int32, Int32}
        pos, inner = pointer_track(e)
        span = inner - 1
        if !@orientation.horizontal? && invert
          {span - pos, span}
        else
          {pos, span}
        end
      end

      # Main-axis pointer offset (cells from the track start) and the inner
      # track extent (cells) for mouse event *e*.
      #
      # Resolves the pointer against the *painted* track when rendered, not the
      # layout coords: mouse events are dispatched by painted geometry, which
      # inside a scrolled container is shifted from the layout coords by the
      # ancestor's scroll base, and an ancestor-clipped track paints compressed
      # into the clipped rect. Both the origin and the extent must come from
      # that same rect or a seek lands on the wrong value — so each edge is
      # inset by the *visible* remainder of its border/padding band
      # (`effective_edge_insets` over `lp.hidden_*`), never the full widths.
      # Falls back to layout coords before the first render.
      #
      # With *pad* (the default) the padding participates in the inset — the
      # `with_content_coords` interior the mixin's value-track users
      # (`Slider`, `ProgressBar`) paint into; `pad: false` insets by the
      # border alone, matching `ScrollBar`'s `with_inner_coords` track.
      protected def pointer_track(e, pad : Bool = true) : {Int32, Int32}
        border = style.border
        padding = style.padding
        if lp = @lpos
          if @orientation.horizontal?
            txi = lp.xi + track_edge_inset(border.left, padding.left, lp.hidden_left, pad)
            txl = lp.xl - track_edge_inset(border.right, padding.right, lp.hidden_right, pad)
            {e.x - txi, txl - txi}
          else
            tyi = lp.yi + track_edge_inset(border.top, padding.top, lp.hidden_top, pad)
            tyl = lp.yl - track_edge_inset(border.bottom, padding.bottom, lp.hidden_bottom, pad)
            {e.y - tyi, tyl - tyi}
          end
        elsif @orientation.horizontal?
          inset = pad ? ileft : border.left
          {e.x - aleft - inset, awidth - (pad ? ihorizontal : border.left + border.right)}
        else
          inset = pad ? itop : border.top
          {e.y - atop - inset, aheight - (pad ? ivertical : border.top + border.bottom)}
        end
      end

      # The effective inset of one track edge: the visible remainder of the
      # border band — plus, when *pad*, the padding band — after any
      # ancestor-clip (*hidden*) consumed its share.
      private def track_edge_inset(border_w : Int32, padding_w : Int32, hidden : Int32, pad : Bool) : Int32
        eb, ep = effective_edge_insets(border_w, padding_w, hidden)
        pad ? eb + ep : eb
      end
    end
  end
end
