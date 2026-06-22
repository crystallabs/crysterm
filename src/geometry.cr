module Crysterm
  # Used to represent minimal widget position. It is returned from methods
  # that run calculations to determine that. *i fields are start positions,
  # *l methods are end positions.
  #
  # Used only internally; could be replaced by anything else that has
  # the necessary properties.
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

  # Helper class implementing only minimal position-related interface.
  # Used for holding widget's last rendered position.
  # XXX Could be renamed to LastRenderedPos[ition] for clarity.
  class LPos
    # TODO Can almost be replaced with a struct. Only minimal problems appear.
    # See tech-demo example, fix the issue and replace with struct.

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

    # Informs us which side is partly hidden due to being enclosed in a
    # parent (and potentially scrollable) element.
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

    # These should be allowed to be just 0 because I'd think their offsets
    # are already included in a* properties.
    # (XXX Verify that and fix; seems like an inconsistency in logic if that
    # sentence/description is true.
    property ileft : Int32 = 0
    property itop : Int32 = 0
    property iright : Int32 = 0
    property ibottom : Int32 = 0
    property iwidth : Int32 = 0
    property iheight : Int32 = 0

    property _scroll_bottom : Int32 = 0
    property _clean_sides : Bool = false

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

    # Re-initializes this instance in place to the same state a freshly
    # constructed `LPos.new(xi:, xl:, ...)` would have. Used by
    # `Widget#_get_coords` on the render hot path to reuse the widget's existing
    # `@lpos` instead of allocating a new `LPos` every widget, every frame (the
    # allocation this whole class's `# TODO ... struct` note is about).
    #
    # Besides the geometry fields passed in, this MUST reset the lazily-computed
    # cache fields (`aleft`/`atop`/.../`_clean_sides`) back to their constructor
    # defaults: they are filled on demand by `last_rendered_position`/`clean_sides`
    # and keyed to the *previous* frame's geometry, so a reused instance that kept
    # them would hand back stale absolute positions after a widget moves.
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
      @_clean_sides = false
      self
    end
  end
end
