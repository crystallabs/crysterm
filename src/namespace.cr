module Crysterm
  module Namespace
    #    class Position
    #      @left : Int32
    #      @right : Int32
    #      @top : Int32
    #      @bottom : Int32
    #      @width : Int32
    #      @height : Int32
    #
    #      def initialize(
    #        @left=0,
    #        @right=0,
    #        @top=0,
    #        @bottom=0,
    #        @width=1,
    #        @height=1,
    #      )
    #      end
    #    end
    include Tput::Namespace

    @[Flags]
    enum OptimizationFlag
      FastCSR
      SmartCSR
      BCE
    end

    class BasicStyle
      # Potentially make all subelements be filled in here,
      # and if they're a new Style class have it know its
      # Style parent. This way we could default values to
      # the parent value.
      property fg : String = "white"
      property bg : String = "black"
      property bold : Bool = false
      property underline : Bool = false
      property blink : Bool = false
      property inverse : Bool = false
      property invisible : Bool = false
      property transparent : Float64? = nil
      # property hover : Bool
      # property focus : Bool
      property char : Char = ' '
      property pchar : Char = ' '
      #property fchar : Char = ' '

      # For scrollbar
      property? ignore_border : Bool

      def initialize(
        fg = nil,
        bg = nil,
        bold = nil,
        underline = nil,
        blink = nil,
        inverse = nil,
        invisible = nil,
        transparent = nil,
        char = nil,
        #fchar = nil,
        ignore_border = nil,
      )
        fg.try { |v| @fg = v }
        bg.try { |v| @bg = v }
        bold.try { |v| @bold = v }
        underline.try { |v| @underline = v }
        blink.try { |v| @blink = v }
        inverse.try { |v| @inverse = v }
        invisible.try { |v| @invisible = v }
        transparent.try { |v| @transparent = v.is_a?(Bool) ? (v ? 0.5 : nil) : v }
        char.try { |v| @char = v }
        #fchar.try { |v| @fchar = v }
        ignore_border.try { |v| @ignore_border = v }
      end
    end

    class Style < BasicStyle
      property border : BasicStyle? = BasicStyle.new
      property scrollbar : BasicStyle? = BasicStyle.new
      property track : BasicStyle? = BasicStyle.new
      property bar : BasicStyle? = BasicStyle.new

      def initialize(
        @border = nil,
        @scrollbar = nil,
        @track = nil,
        @bar = nil,
        **basic_style
      )
        super **basic_style
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
  end
end
