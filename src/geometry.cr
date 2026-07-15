module Crysterm
  # An axis-aligned rectangle of terminal cells (Qt's `QRect`), returned from
  # position-calculating methods — most visibly `Widget#contents_rect`.
  #
  # Both axes are **half-open**: the rectangle covers columns `xi...xl` and rows
  # `yi...yl`, so `xl`/`yl` are one past the last cell and `width == xl - xi`.
  # `#right`/`#bottom` are exclusive too, *unlike* Qt's `QRect#right`, which
  # returns the inclusive `x + width - 1`. There is no inclusive variant here.
  struct Rectangle
    # Start column (inclusive).
    getter xi : Int32

    # End column (**exclusive**).
    getter xl : Int32

    # Start row (inclusive).
    getter yi : Int32

    # End row (**exclusive**).
    getter yl : Int32

    def initialize(@xi, @xl, @yi, @yl)
    end

    # Width in cells. The x range is half-open (`xi...xl`).
    def width : Int32
      @xl - @xi
    end

    # Height in cells. The y range is half-open (`yi...yl`).
    def height : Int32
      @yl - @yi
    end

    # :ditto: — `#xi` under its QRect name.
    def x : Int32
      @xi
    end

    # :ditto: — `#yi` under its QRect name.
    def y : Int32
      @yi
    end

    # Left edge (inclusive) — alias of `#xi`.
    def left : Int32
      @xi
    end

    # Top edge (inclusive) — alias of `#yi`.
    def top : Int32
      @yi
    end

    # Right edge, **exclusive** — alias of `#xl`. One past the last covered
    # column, *not* Qt's inclusive `x + width - 1`.
    def right : Int32
      @xl
    end

    # Bottom edge, **exclusive** — alias of `#yl`. One past the last covered
    # row; see `#right`.
    def bottom : Int32
      @yl
    end

    # Whether the rectangle covers no cells (either axis collapsed or inverted).
    def empty? : Bool
      @xl <= @xi || @yl <= @yi
    end

    # Center cell, rounded down (the exact center of an even-sized side falls
    # between two cells; the lower one is taken).
    def center : Tuple(Int32, Int32)
      {@xi + width // 2, @yi + height // 2}
    end

    # Whether the absolute cell (*x*, *y*) falls inside this rectangle.
    def contains?(x : Int32, y : Int32) : Bool
      x >= @xi && x < @xl && y >= @yi && y < @yl
    end

    # Whether *other* shares at least one cell with this rectangle. An empty
    # rectangle intersects nothing.
    def intersects?(other : Rectangle) : Bool
      @xi < other.xl && other.xi < @xl && @yi < other.yl && other.yi < @yl
    end

    # This rectangle shifted by (*dx*, *dy*), keeping its size.
    def translated(dx : Int32, dy : Int32) : Rectangle
      Rectangle.new @xi + dx, @xl + dx, @yi + dy, @yl + dy
    end

    # Intersection with *other* — the cells in both. `#empty?` when they don't
    # overlap (the result is normalized rather than inverted).
    def &(other : Rectangle) : Rectangle
      xi = Math.max @xi, other.xi
      xl = Math.min @xl, other.xl
      yi = Math.max @yi, other.yi
      yl = Math.min @yl, other.yl
      Rectangle.new xi, Math.max(xi, xl), yi, Math.max(yi, yl)
    end

    # Bounding rectangle of `self` and *other* — the smallest rectangle covering
    # both. Not a set union: cells in neither operand may be covered. An empty
    # operand is ignored, so `empty | r == r` rather than a rectangle stretched
    # to some stale origin.
    def |(other : Rectangle) : Rectangle
      return other if empty?
      return self if other.empty?
      Rectangle.new Math.min(@xi, other.xi), Math.max(@xl, other.xl),
        Math.min(@yi, other.yi), Math.max(@yl, other.yl)
    end
  end

  # A widget's last rendered position: the rectangle it painted into, plus the
  # absolute offsets and insets resolved from it (the `a*`/`i*` fields fill
  # lazily).
  #
  # Instances are **reused across frames** and mutated in place, keeping a heap
  # allocation per widget per frame off the render hot path. Read the values;
  # never retain the object past the current frame.
  class RenderedGeometry
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
    property ihorizontal : Int32 = 0
    property ivertical : Int32 = 0

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
      @ihorizontal = @ihorizontal,
      @ivertical = @ivertical,
    )
    end

    # Re-initializes this instance in place to a freshly-constructed state, so the
    # render hot path can reuse a widget's `@lpos` rather than allocate.
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
      @ihorizontal = 0
      @ivertical = 0
      @_scroll_bottom = 0
      @_clean_sides = nil
      self
    end
  end
end
