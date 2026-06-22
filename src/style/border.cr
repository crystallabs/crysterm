module Crysterm
  # Type of border to draw.
  enum BorderType
    Bg   # Bg color
    Line # Line, drawn in ACS or Unicode chars
    # Dotted
    # Dashed
    # Solid
    # Double
    # DotDash
    # DotDotDash
    # Groove
    # Ridge
    # Inset
    # Outset
  end

  # Class for border definition.
  class Border
    include Colorizable
    include SidedGeometry

    property type = BorderType::Line

    # Border colors. Native form is a `0xRRGGBB` int (`-1` = terminal default,
    # `nil` = unset); `"#rrggbb"`/named strings are accepted for backwards
    # compatibility and parsed via `Colors.convert`. See `Style#fg`. The setters
    # come from `Colorizable`.
    getter bg : Int32?
    getter fg : Int32?

    property char = ' '
    # XXX There is some duplication between style and these 5.
    # They must be present for sattr() to be able to work on the Border object.
    # But on the other hand, it allows these features which do not exist in Blessed.
    property? bold : Bool = false
    property? italic : Bool = false
    property? underline : Bool = false
    property? blink : Bool = false
    property? inverse : Bool = false
    property? visible : Bool = true

    property left = 1
    property top = 1
    property right = 1
    property bottom = 1

    def self.from(value)
      case value
      in true
        Border.new
      in nil, false
        Border.new 0
      in BorderType
        Border.new value
      in Border
        value
      in Int
        Border.new value, value, value, value
      end
    end

    def initialize(
      @type = @type,
      bg = nil,
      fg = nil,
      @left = @left,
      @top = @top,
      @right = @right,
      @bottom = @bottom,
    )
      # Route through the setters so a native int or a `"#rrggbb"`/named string
      # both resolve to the native int form.
      self.bg = bg unless bg.nil?
      self.fg = fg unless fg.nil?
    end

    def initialize(all : Int)
      @left = @top = @right = @bottom = all
    end

    def initialize(@left : Int, @top : Int, @right : Int, @bottom : Int)
    end

    # XXX enable these two after -Dpreview_overload_order becomes the default
    # def initialize(left_and_right, top_and_bottom)
    #  @left = @right = left_and_right
    #  @top = @bottom = top_and_bottom
    # end

    # def initialize(all : Bool = true)
    #  @left = @top = @right = @bottom = all
    # end

    # Per-side predicates (`left?`/`top?`/`right?`/`bottom?`), `any?` and
    # `adjust` come from `SidedGeometry`.
  end
end
