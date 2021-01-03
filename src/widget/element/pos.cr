module Crysterm::Widget
  class Element < Node
    module Pos

      property renders = 0

      property left=0
      property top=0
      property right=0
      property bottom=0

      property aleft=0
      property atop=0
      property aright=0
      property abottom=0

      property rleft=0
      property rtop=0
      property rright=0
      property rbottom=0

      property position = Tput::Position.new

      # XXX Turn these to Position struct
      property ileft=0
      property itop=0
      property iright=0
      property ibottom=0
      property iwidth=0
      property iheight=0

      # Heh.
      property? scrollable = false

      property border = Tput::Border.new

      property lpos : LPos = LPos.new

      class LPos
        property xi : Int32=0
        property xl : Int32=0
        property yi : Int32=0
        property yl : Int32=0
        property base : Int32=0
        property noleft : Bool=false
        property noright : Bool=false
        property notop : Bool=false
        property nobot : Bool=false
        property renders = 0

        property aleft : Int32 = 0
        property atop : Int32 = 0
        property aright : Int32 = 0
        property abottom : Int32 = 0
        property width : Int32 = 0
        property height : Int32 = 0

        property ileft : Int32 = 0
        property itop : Int32 = 0
        property iright : Int32 = 0
        property ibottom : Int32 = 0

        def initialize(
          @xi =0,
          @xl =0,
          @yi =0,
          @yl =0,
          @base =0,
          @noleft =false,
          @noright =false,
          @notop =false,
          @nobot =false,
          @renders =0,
          @aleft  = 0,
          @atop  = 0,
          @aright  = 0,
          @abottom  = 0,
          @width  = 0,
          @height  = 0,
        )
        end
      end
    end
  end
end
