module Crysterm
  class Element < Node
    module Pos
      property renders = 0

      # Absolute left offset.
      property aleft : Int32? = nil

      # Absolute top offset.
      property atop : Int32? = nil

      # Absolute right offset.
      property aright : Int32? = nil

      # Absolute bottom offset.
      property abottom : Int32? = nil

      # Relative coordinates as default properties
      def left
        @rleft
      end

      def right
        @rright
      end

      def top
        @rtop
      end

      def bottom
        @rbottom
      end

      def left=(arg)
        @rleft = arg
      end

      def right=(arg)
        @rright = arg
      end

      def top=(arg)
        @rtop = arg
      end

      def bottom=(arg)
        @rbottom = arg
      end

      # Heh.
      property? scrollable = false

      property lpos : LPos? = nil

      class LPos
        property xi : Int32 = 0
        property xl : Int32 = 0
        property yi : Int32 = 0
        property yl : Int32 = 0
        property base : Int32 = 0
        property noleft : Bool = false
        property noright : Bool = false
        property notop : Bool = false
        property nobot : Bool = false
        property renders = 0

        property aleft : Int32? = nil
        property atop : Int32? = nil
        property aright : Int32? = nil
        property abottom : Int32? = nil
        property width : Int32? = nil
        property height : Int32? = nil

        #property ileft : Int32 = 0
        #property itop : Int32 = 0
        #property iright : Int32 = 0
        #property ibottom : Int32 = 0

        def initialize(
          @xi = 0,
          @xl = 0,
          @yi = 0,
          @yl = 0,
          @base = 0,
          @noleft = false,
          @noright = false,
          @notop = false,
          @nobot = false,
          @renders = 0,

          # Disable all this:
          @aleft = nil,
          @atop = nil,
          @aright = nil,
          @abottom = nil,
          @width = nil,
          @height = nil
        )
        end
      end
    end
  end
end
