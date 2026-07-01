module Crysterm
  # Minimal widget position, returned from position-calculating methods. *i
  # fields are start positions, *l end positions. Internal only.
  struct Rectangle
    getter xi : Int32
    getter xl : Int32
    getter yi : Int32
    getter yl : Int32
    getter get : Bool

    # NOTE Don't remember the exact function of `get`. IIRC it goes to
    # recalculate from parent. Check what the function is and document
    # it here.
    def initialize(@xi, @xl, @yi, @yl, @get = false)
    end
  end

  # Minimal position interface holding a widget's last rendered position.
  # XXX Could be renamed to LastRenderedPos[ition] for clarity.
  class LPos
    # TODO Can almost be replaced with a struct; see tech-demo example.

    None = new

    # Starting cell on X axis
    property xi : Int32 = 0

    # Ending cell on X axis
    property xl : Int32 = 0

    # Starting cell on Y axis
    property yi : Int32 = 0

    # Endint cell on Y axis
    property yl : Int32 = 0

    property base : Int32 = 0

    # Which side is partly hidden by an enclosing (scrollable) parent.
    property? no_left : Bool = false
    property? no_right : Bool = false
    property? no_top : Bool = false
    property? no_bottom : Bool = false

    # Number of times object was rendered
    property renders = 0

    property aleft : Int32? = nil
    property atop : Int32? = nil
    property aright : Int32? = nil
    property abottom : Int32? = nil
    property awidth : Int32? = nil
    property aheight : Int32? = nil

    # XXX Verify: should be allowed to be just 0 since offsets are likely
    # already included in a* properties.
    property ileft : Int32 = 0
    property itop : Int32 = 0
    property iright : Int32 = 0
    property ibottom : Int32 = 0
    property iwidth : Int32 = 0
    property iheight : Int32 = 0

    property _scroll_bottom : Int32 = 0
    property _clean_sides : Bool? = nil

    def initialize(
      @xi = @xi,
      @xl = @xl,
      @yi = @yi,
      @yl = @yl,
      @base = @base,
      @no_left = @no_left,
      @no_right = @no_right,
      @no_top = @no_top,
      @no_bottom = @no_bottom,

      @renders = @renders,

      # Disable all this:
      @aleft = @aleft,
      @atop = @atop,
      @aright = @aright,
      @abottom = @abottom,
      @awidth = @awidth,
      @aheight = @aheight,

      @ileft = @ileft,
      @itop = @itop,
      @iright = @iright,
      @ibottom = @ibottom,
      @iwidth = @iwidth,
      @iheight = @iheight,
    )
    end

    # Re-initializes this instance in place to a freshly-constructed state. Used
    # by `Widget#_get_coords` on the render hot path to reuse the widget's
    # `@lpos` instead of allocating a new `LPos` per widget per frame.
    #
    # MUST reset the lazily-computed cache fields (`aleft`/.../`_clean_sides`):
    # they're keyed to the previous frame's geometry and would otherwise return
    # stale absolute positions after a widget moves.
    def reset(
      @xi,
      @xl,
      @yi,
      @yl,
      @base,
      @no_left,
      @no_right,
      @no_top,
      @no_bottom,
      @renders,
    ) : self
      @aleft = nil
      @atop = nil
      @aright = nil
      @abottom = nil
      @awidth = nil
      @aheight = nil
      @ileft = 0
      @itop = 0
      @iright = 0
      @ibottom = 0
      @iwidth = 0
      @iheight = 0
      @_scroll_bottom = 0
      @_clean_sides = nil
      self
    end
  end
end
