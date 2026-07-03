module Crysterm
  class Widget
    # Widget decorations

    # The `{ileft, itop, iright, ibottom}` inner insets, cached per frame. Each
    # getter previously resolved `#style` twice (border + padding), and they
    # fire many times per widget per frame: per auto-sized child (`awidth`'s nil
    # branch reads the parent's), ×4 per container in `Layout#interior_coords`,
    # and inside `_render`'s clip guards. Validity is tied to the frame-memoized
    # style: `#style` clears this on every (re)resolution, and
    # `#invalidate_frame_style` clears both.
    @_frame_insets : Tuple(Int32, Int32, Int32, Int32)?

    private def frame_insets : Tuple(Int32, Int32, Int32, Int32)
      # `#style` first: on a new frame (or after invalidation) it re-resolves
      # and resets `@_frame_insets`, so a surviving value is current.
      st = style
      if fi = @_frame_insets
        return fi
      end
      p = st.padding
      fi = if b = st.border
             {b.left + p.left, b.top + p.top, b.right + p.right, b.bottom + p.bottom}
           else
             {p.left, p.top, p.right, p.bottom}
           end
      @_frame_insets = fi
      fi
    end

    # Returns computed content offset from left
    def ileft
      frame_insets[0]
    end

    # Returns computed content offset from top
    def itop
      frame_insets[1]
    end

    # Returns computed content offset from right
    def iright
      frame_insets[2]
    end

    # Returns computed content offset from bottom
    def ibottom
      frame_insets[3]
    end

    # Returns summed amount of content offset from left and right
    def iwidth
      fi = frame_insets
      fi[0] + fi[2]
    end

    # Returns summed amount of content offset from top and bottom
    def iheight
      fi = frame_insets
      fi[1] + fi[3]
    end

    # Outer (margin) offsets. Counterpart to the inner `i*` offsets above,
    # applied to the resolved rectangle in `#_get_coords`. Used by
    # shrink-to-content sizing (`widget_size.cr`) so margin doesn't eat into a
    # shrunk widget's content.

    # Margin offset on the left side
    def mleft
      style.margin.left
    end

    # Margin offset on the top side
    def mtop
      style.margin.top
    end

    # Margin offset on the right side
    def mright
      style.margin.right
    end

    # Margin offset on the bottom side
    def mbottom
      style.margin.bottom
    end

    # Summed margin offset from left and right
    def mwidth
      style.margin.left + style.margin.right
    end

    # Summed margin offset from top and bottom
    def mheight
      style.margin.top + style.margin.bottom
    end
  end
end
