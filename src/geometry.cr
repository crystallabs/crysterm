module Crysterm
  # A single cell position — Qt's `QPoint`.
  record Point, x : Int32, y : Int32 do
    # Componentwise sum — Qt's `QPoint::operator+`.
    def +(other : Point) : Point
      Point.new @x + other.x, @y + other.y
    end

    # Componentwise difference — Qt's `QPoint::operator-`.
    def -(other : Point) : Point
      Point.new @x - other.x, @y - other.y
    end
  end

  # A cell extent — Qt's `QSize`.
  record Size, width : Int32, height : Int32 do
    # Whether either dimension is non-positive — Qt's `QSize::isEmpty()`.
    def empty? : Bool
      @width <= 0 || @height <= 0
    end

    # Cell count covered — `#width * #height`.
    def area : Int32
      @width * @height
    end

    # Shrunk to fit within *other* on both axes independently — Qt's
    # `QSize::boundedTo`.
    def bounded_to(other : Size) : Size
      Size.new Math.min(@width, other.width), Math.min(@height, other.height)
    end

    # Grown to cover *other* on both axes independently — Qt's
    # `QSize::expandedTo`.
    def expanded_to(other : Size) : Size
      Size.new Math.max(@width, other.width), Math.max(@height, other.height)
    end
  end

  # An axis-aligned rectangle of terminal cells (Qt's `QRect`), returned from
  # position-calculating methods — most visibly `Widget#contents_rect`.
  #
  # The primary constructor takes Qt's `x, y, width, height` order, matching
  # `QRect(int x, int y, int width, int height)`. For the half-open edge form
  # (`left, top, right, bottom`) — handy when the caller already has edges in
  # hand, e.g. intersection/union math — use `.of_edges`.
  #
  # Both axes are **half-open**: the rectangle covers columns `xi...xl` and rows
  # `yi...yl`, so `xl`/`yl` are one past the last cell and `width == xl - xi`.
  # `#right`/`#bottom` are exclusive too, *unlike* Qt's `QRect#right`, which
  # returns the inclusive `x + width - 1`. There is no inclusive variant here.
  # The derived readers shared by every half-open `xi/xl/yi/yl` box — `Rectangle`
  # (the immutable value type) and `RenderedGeometry` (the per-frame mutable
  # backing store). Both carry identical edge semantics, so the size/edge/
  # containment math lives here once.
  #
  # Written against the `#xi`/`#xl`/`#yi`/`#yl` **getters**, never the ivars, so
  # it applies unchanged to a `struct` with `getter` and a `class` with
  # `property`. Only the scalar/derived readers belong here; the
  # `Rectangle`-valued API (`#center`, `#contains?(Rectangle)`, `#intersects?`,
  # `#translated`, `#&`, `#|`, corner points) stays on `Rectangle`.
  module RectEdges
    # Width in cells. The x range is half-open (`xi...xl`).
    def width : Int32
      xl - xi
    end

    # Height in cells. The y range is half-open (`yi...yl`).
    def height : Int32
      yl - yi
    end

    # `#xi` under its QRect name.
    def x : Int32
      xi
    end

    # `#yi` under its QRect name.
    def y : Int32
      yi
    end

    # Left edge (inclusive) — alias of `#xi`.
    def left : Int32
      xi
    end

    # Top edge (inclusive) — alias of `#yi`.
    def top : Int32
      yi
    end

    # Right edge, **exclusive** — alias of `#xl`. One past the last covered
    # column, *not* Qt's inclusive `x + width - 1`.
    def right : Int32
      xl
    end

    # Bottom edge, **exclusive** — alias of `#yl`. One past the last covered
    # row; see `#right`.
    def bottom : Int32
      yl
    end

    # Whether the box covers no cells (either axis collapsed or inverted).
    def empty? : Bool
      xl <= xi || yl <= yi
    end

    # Whether the absolute cell (*x*, *y*) falls inside this box.
    def contains?(x : Int32, y : Int32) : Bool
      x >= xi && x < xl && y >= yi && y < yl
    end
  end

  struct Rectangle
    include RectEdges

    # Start column (inclusive).
    getter xi : Int32

    # End column (**exclusive**).
    getter xl : Int32

    # Start row (inclusive).
    getter yi : Int32

    # End row (**exclusive**).
    getter yl : Int32

    def initialize(x : Int32, y : Int32, width : Int32, height : Int32)
      @xi = x
      @yi = y
      @xl = x + width
      @yl = y + height
    end

    # `top_left` + `size` overload — Qt's `QRect(QPoint, QSize)`.
    def initialize(top_left : Point, size : Size)
      initialize top_left.x, top_left.y, size.width, size.height
    end

    # `top_left` + `bottom_right` overload — Qt's `QRect(QPoint, QPoint)`.
    # *bottom_right* is the half-open exclusive corner (see the class docs
    # above), matching `#bottom_right`/`.of_edges`, NOT Qt's inclusive corner.
    def initialize(top_left : Point, bottom_right : Point)
      initialize top_left.x, top_left.y, bottom_right.x - top_left.x, bottom_right.y - top_left.y
    end

    # Alternate constructor taking half-open edges directly (`left...right`,
    # `top...bottom`) rather than an origin + size.
    def self.of_edges(left : Int32, top : Int32, right : Int32, bottom : Int32) : Rectangle
      new left, top, right - left, bottom - top
    end

    # Center cell, rounded down (the exact center of an even-sized side falls
    # between two cells; the lower one is taken).
    def center : Point
      Point.new @xi + width // 2, @yi + height // 2
    end

    # Top-left corner, i.e. `(x, y)` — Qt's `QRect::topLeft()`.
    def top_left : Point
      Point.new @xi, @yi
    end

    # :ditto: — alias of `#top_left`, Qt's `QRect::topLeft()` seen as the
    # rectangle's own position.
    def position : Point
      top_left
    end

    # Top-right corner. Exclusive on the x axis, like `#right`.
    def top_right : Point
      Point.new @xl, @yi
    end

    # Bottom-left corner. Exclusive on the y axis, like `#bottom`.
    def bottom_left : Point
      Point.new @xi, @yl
    end

    # Bottom-right corner. Exclusive on both axes, like `#right`/`#bottom`.
    def bottom_right : Point
      Point.new @xl, @yl
    end

    # This rectangle's extent — Qt's `QRect::size()`.
    def size : Size
      Size.new width, height
    end

    # Whether the absolute cell of *point* falls inside this rectangle.
    def contains?(point : Point) : Bool
      contains? point.x, point.y
    end

    # Whether *other* falls entirely inside this rectangle (every cell of
    # *other* is also a cell of `self`) — Qt's `QRect::contains(QRect)`.
    def contains?(other : Rectangle) : Bool
      other.xi >= @xi && other.xl <= @xl && other.yi >= @yi && other.yl <= @yl
    end

    # Whether *other* shares at least one cell with this rectangle. An empty
    # rectangle intersects nothing.
    def intersects?(other : Rectangle) : Bool
      @xi < other.xl && other.xi < @xl && @yi < other.yl && other.yi < @yl
    end

    # This rectangle shifted by (*dx*, *dy*), keeping its size.
    def translated(dx : Int32, dy : Int32) : Rectangle
      Rectangle.of_edges @xi + dx, @yi + dy, @xl + dx, @yl + dy
    end

    # `Point` overload of `#translated` — Qt's `QRect::translated(QPoint)`.
    def translated(point : Point) : Rectangle
      translated point.x, point.y
    end

    # Each edge nudged independently by (*dl*, *dt*, *dr*, *db*) — Qt's
    # `QRect::adjusted(dx1, dy1, dx2, dy2)`. `dr`/`db` move the (exclusive)
    # `#right`/`#bottom` edge, so `adjusted(0, 0, 1, 1)` grows the rectangle by
    # one cell on the far edges, matching Qt's inclusive-corner `adjusted`
    # despite the different edge convention.
    def adjusted(dl : Int32, dt : Int32, dr : Int32, db : Int32) : Rectangle
      Rectangle.of_edges @xi + dl, @yi + dt, @xl + dr, @yl + db
    end

    # This rectangle repositioned so its top-left is (*x*, *y*), keeping its
    # size — Qt's `QRect::moveTo`.
    def move_to(x : Int32, y : Int32) : Rectangle
      Rectangle.new x, y, width, height
    end

    # `Point` overload of `#move_to`.
    def move_to(point : Point) : Rectangle
      move_to point.x, point.y
    end

    # This rectangle with its extent replaced by (*w*, *h*), keeping its
    # top-left — Qt's `QRect::setSize`.
    def with_size(w : Int32, h : Int32) : Rectangle
      Rectangle.new @xi, @yi, w, h
    end

    # `Size` overload of `#with_size`.
    def with_size(size : Size) : Rectangle
      with_size size.width, size.height
    end

    # This rectangle grown outward by *other* (margins) — Qt's
    # `QRect::marginsAdded`. The by-value counterpart of
    # `SidedGeometry#adjust(sign: -1)`.
    def +(other : SidedGeometry) : Rectangle
      other.outset self
    end

    # This rectangle shrunk inward by *other* (margins) — Qt's
    # `QRect::marginsRemoved`. The by-value counterpart of
    # `SidedGeometry#adjust(sign: 1)`.
    def -(other : SidedGeometry) : Rectangle
      other.inset self
    end

    # Intersection with *other* — the cells in both. `#empty?` when they don't
    # overlap (the result is normalized rather than inverted).
    def &(other : Rectangle) : Rectangle
      xi = Math.max @xi, other.xi
      xl = Math.min @xl, other.xl
      yi = Math.max @yi, other.yi
      yl = Math.min @yl, other.yl
      Rectangle.of_edges xi, yi, Math.max(xi, xl), Math.max(yi, yl)
    end

    # Bounding rectangle of `self` and *other* — the smallest rectangle covering
    # both. Not a set union: cells in neither operand may be covered. An empty
    # operand is ignored, so `empty | r == r` rather than a rectangle stretched
    # to some stale origin.
    def |(other : Rectangle) : Rectangle
      return other if empty?
      return self if other.empty?
      Rectangle.of_edges Math.min(@xi, other.xi), Math.min(@yi, other.yi),
        Math.max(@xl, other.xl), Math.max(@yl, other.yl)
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
    # The half-open box's derived readers (`#width`/`#height`/`#x`/`#y`/`#left`/
    # `#top`/`#right`/`#bottom`/`#empty?`/`#contains?`) come from the shared
    # module rather than being restated here — the edge semantics are `Rectangle`'s.
    include RectEdges

    # Deliberately a class, not a `struct`: instances are reused and mutated in
    # place across a frame and shared by reference (see the "reused across
    # frames" note above), which a value-type `struct` — copied on every
    # assignment — would break. The value-type geometry analogue (Qt's `QRect`)
    # is the `Rectangle` struct; this is the per-frame mutable backing store.

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

    # Rows/columns of the widget hidden past the clipping ancestor's viewport on
    # each edge (0 when the edge is not clipped; the matching `no_*` flag is set
    # whenever one of these is positive). The rectangle itself is clamped to the
    # viewport, so these carry how much was cut away — the renderer uses them to
    # derive how much of a clipped edge's border/padding band is still visible.
    property hidden_left : Int32 = 0
    property hidden_right : Int32 = 0
    property hidden_top : Int32 = 0
    property hidden_bottom : Int32 = 0

    # Number of times object was rendered
    property renders = 0

    property aleft : Int32? = nil
    property atop : Int32? = nil
    property aright : Int32? = nil
    property abottom : Int32? = nil
    property awidth : Int32? = nil
    property aheight : Int32? = nil

    # The inner insets (border + padding, per edge) — distinct from the `a*`
    # absolute-position fields above. The `0` default is a pre-render placeholder:
    # `Widget#_render` overwrites all six every frame from the widget's resolved
    # `#ileft`/`#itop`/… (`pos.ileft = ileft`, …), so a freshly-`reset` geometry
    # reads `0` only until the next render.
    property ileft : Int32 = 0
    property itop : Int32 = 0
    property iright : Int32 = 0
    property ibottom : Int32 = 0
    property ihorizontal : Int32 = 0
    property ivertical : Int32 = 0

    property _scroll_bottom : Int32 = 0
    property _clean_sides : Bool? = nil

    # This box's extent — `Rectangle#size` parity, Qt's `QRect::size()`.
    def size : Size
      Size.new width, height
    end

    # Top-left corner, i.e. `(x, y)` — `Rectangle#top_left` parity, Qt's
    # `QRect::topLeft()`.
    def top_left : Point
      Point.new xi, yi
    end

    # Center cell, rounded down — `Rectangle#center` parity (same rounding:
    # the lower cell wins on an even-sized side).
    def center : Point
      Point.new xi + width // 2, yi + height // 2
    end

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

      @hidden_left = @hidden_left,
      @hidden_right = @hidden_right,
      @hidden_top = @hidden_top,
      @hidden_bottom = @hidden_bottom,

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
      @hidden_left = 0,
      @hidden_right = 0,
      @hidden_top = 0,
      @hidden_bottom = 0,
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
