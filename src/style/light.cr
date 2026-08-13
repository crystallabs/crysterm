module Crysterm
  # The scene's light source: the single fact that relief shading
  # (`Border#relief`) and shadow placement (`Shadow`) are both projections
  # of. `Window#light` holds the scene default (`DEFAULT` — light from the
  # northwest, parallel rays — reproduces the classic hardcoded top-left
  # assumption bit for bit), and any widget can override it via
  # `Style#light`.
  #
  # The `kind` does *not* vary shading by a widget's position on screen — a
  # `Spot` shades every widget identically; it only changes each widget's
  # cast shadow *shape* (see `Kind`).
  record Light, direction : Direction = Direction::NW, kind : Kind = Kind::Directional do
    # Where the light sits relative to the scene, 8-way.
    enum Direction
      N
      NE
      E
      SE
      S
      SW
      W
      NW

      # The east-west component of the light's bearing: `+1` when the light
      # has an eastern component (E/NE/SE — right edges face it), `-1` for
      # western, `0` for the N/S cardinals.
      def east : Int32
        case self
        in .ne?, .e?, .se? then 1
        in .nw?, .w?, .sw? then -1
        in .n?, .s?        then 0
        end
      end

      # The north-south component: `+1` when the light has a northern
      # component (N/NE/NW — top edges face it), `-1` for southern, `0` for
      # the E/W cardinals.
      def north : Int32
        case self
        in .nw?, .n?, .ne? then 1
        in .sw?, .s?, .se? then -1
        in .e?, .w?        then 0
        end
      end
    end

    # How the light's rays travel — the widget's cast shadow *shape*.
    enum Kind
      # Parallel rays ("isometric"): a widget's cast shadow is its exact
      # silhouette — a N light drops a bottom band exactly the widget's
      # width.
      Directional

      # A point source sitting on the direction axis (a N spot is centered
      # above the scene): rays diverge like a cone, so the cast shadow comes
      # out slightly larger than the widget — each shadow band spills one
      # cell past its free ends (a N spot's bottom band runs from one cell
      # left of the widget to one cell right of it; the joined ends of a
      # diagonal light's two bands still meet at the corner).
      Spot
    end

    # The classic default: light from the northwest, parallel rays — the
    # top-left assumption every fixed-light toolkit (Qt, CSS, Motif) bakes
    # in, made explicit.
    DEFAULT = new

    # Which way *side* faces relative to the light: `+1` lit (facing the
    # light), `-1` shaded (facing away), `0` neutral (parallel to the rays —
    # a cardinal light leaves the two perpendicular sides untouched). This
    # single classification feeds relief shading, the weight-bevel rendition
    # and shadow placement, so they can never disagree about where the light
    # is.
    def lit(side : Side) : Int32
      case side
      in .top?    then direction.north
      in .bottom? then -direction.north
      in .left?   then -direction.east
      in .right?  then direction.east
      in .horizontal?, .vertical?, .all?
        raise ArgumentError.new "Light#lit expects a single side, got #{side}"
      end
    end

    # Whether *side* is one the shadow falls on: the sides facing away from
    # the light (light NW → right+bottom, the classic; light N → bottom
    # only).
    def shadow_side?(side : Side) : Bool
      lit(side) < 0
    end

    # Coerces *value* into a `Light`: a `Light` passes through; a
    # `Direction` (or its symbol, `:nw`) keeps the default directional kind.
    def self.from(value : Light | Direction | Symbol) : Light
      case value
      in Light     then value
      in Direction then new(value)
      in Symbol    then new(Direction.parse(value.to_s))
      end
    end
  end
end
