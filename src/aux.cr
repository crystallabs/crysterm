module Crysterm

  class Style
    property fg : String
    property bg : String
    property bold : Bool
    property underline : Bool
    property blink : Bool
    property inverse : Bool
    property invisible : Bool
    property transparent : Bool
    # property hover : Bool
    # property focus : Bool
    property border : Style? = nil

    def initialize(
      @fg = "white",
      @bg = "black",
      @bold = false,
      @underline = false,
      @blink = false,
      @inverse = false,
      @invisible = false,
      @transparent = false,
      @border = nil
    )
    end
  end

  class Padding
    property left : Int32
    property top : Int32
    property right : Int32
    property bottom : Int32

    def initialize(all)
      @left = @top = @right = @bottom = all
    end

    def initialize(@left = 0, @top = 0, @right = 0, @bottom = 0)
    end

    def any?
      (@left + @top + @right + @bottom) > 0
    end
  end

  class Border
    property type = BorderType::Bg
    property ch = ' '
    property left : Bool = true
    property top : Bool = true
    property right : Bool = true
    property bottom : Bool = true

    def initialize(
      @type = BorderType::Bg,
      @ch = ' ',
      @left = true,
      @top = true,
      @right = true,
      @bottom = true
    )
    end

    def any?
      !!((@type != BorderType::None) && (@left || @top || @right || @bottom))
    end
  end

  class BorderSomething
    property fg
    property bg
  end

  enum BorderType
    None
    Bg
    Fg
    Line
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

  class FocusEffects
    property bg
  end

  class HoverEffects
    property bg : String = "black"
  end

  enum LayoutType
    Inline = 1
    Grid   = 2
  end

  enum Overflow
    Ignore
    ShrinkElement
    SkipElement
    StopRendering
  end

  class RPosition
    @element : Element

    setter left : Int32 | String | Nil
    setter top : Int32 | String | Nil
    setter right : Int32 | Nil
    setter bottom : Int32 | Nil
    setter width : Int32 | String | Nil
    setter height : Int32 | String | Nil
    property? resizable = false

    def initialize(@element, @left = nil, @top = nil, @right = nil, @bottom = nil, width = nil, height = nil)
      if width == "resizable"
        @resizable = true
      else
        @width = width
      end

      if height == "resizable"
        @resizable = true
      else
        @height = height
      end
    end

    def left(get = false)
      case v = @left
      when Int
        v
      when String
        if v == "center"
          v = "50%"
        end
        expr = v.split /(?=\+|-)/
        v = expr[0]
        v = v[0...-1].to_f / 100
        v = ((@element.parent.try(&.width) || 0) * v).to_i
        v += expr[1].to_i if expr[1]?
        if @left == "center"
          v -= (@element._get_width(get)) // 2
        end
        v
      end
    end
    def top(get=false)
      case v = @top
      when Int
        v
      when String
        if (v == "center")
          v = "50%"
        end
        expr = v.split(/(?=\+|-)/)
        v = expr[0]
        v = v[0...-1].to_f / 100
        v = ((@element.parent.try &.height || 0) * v).to_i
        v += expr[1].to_i if expr[1]?
        if @top == "center"
          v -= @element._get_height(get) // 2
        end
      end
    end
    def right(get=false)
      case v = @right
      when Int
        v
      end
    end
    def bottom(get=false)
      case v = @bottom
      when Int
        v
      end
    end
    def width(get=false)
      case v = @width
      when Int
        v
      when String
        if v == "half"
          v = "50%"
        end
        expr = v.split /(?=\+|-)/
        v = expr[0]
        v = v[0...-1].to_f / 100
        v = ((@element.parent.try(&.width) || 0) * v).to_i
        v += expr[1].to_i if expr[1]?
        v
      end
    end
    def height(get=false)
      case v = @height
      when Int
        v
      when String
        if v == "half"
          v = "50%"
        end
        expr = v.split /(?=\+|-)/
        v = expr[0]
        v = v[0...-1].to_f / 100
        v = ((@element.parent.try &.height || 0) * v).to_i
        v += expr[1].to_i if expr[1]?
        v
      end
    end
  end

end
