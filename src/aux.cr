module Crysterm

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

    class Style
      property fg : String
      property bg : String
      property bold : Bool
      property underline : Bool
      property blink : Bool
      property inverse : Bool
      property invisible : Bool
      property transparent : Bool
      #property hover : Bool
      #property focus : Bool
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
        @border = nil,
      )
      end
    end

    class Padding
      @left : Int32
      @top : Int32
      @right : Int32
      @bottom : Int32

      def initialize(
        @left=0,
        @top=0,
        @right=0,
        @bottom=0
      )
      end

      def initialize(all=0)
        @left = @top = @right = @bottom = all
      end
    end

    #class Border
    #  @left : Int32
    #  @top : Int32
    #  @right : Int32
    #  @bottom : Int32

    #  def initialize(
    #    @left=0,
    #    @top=0,
    #    @right=0,
    #    @bottom=0
    #  )
    #  end

    #  def initialize(all)
    #    @left = @top = @right = @bottom = all
    #  end
    #end

    class HoverEffects
      @bg : String = "black"
    end

    enum LayoutType
      Inline = 1
      Grid = 2
    end
end
