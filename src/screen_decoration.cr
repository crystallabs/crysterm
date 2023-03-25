module Crysterm
  class Screen
    # For compatibility with widgets. But, as a side-effect, screens can have padding!
    # If you define widget at position (0,0), that will be counted after padding.
    # (We leave this at nil for no padding. If we used Padding.new that'd create a
    # 1 cell padding by default.)
    property padding : Padding?

    def ileft
      @padding.try(&.left) || 0
    end

    def itop
      @padding.try(&.top) || 0
    end

    def iright
      @padding.try(&.right) || 0
    end

    def ibottom
      @padding.try(&.bottom) || 0
    end

    # Returns current screen width.
    def iwidth
      @padding.try do |padding|
        padding.left + padding.right
      end || 0
    end

    # Returns current screen height.
    def iheight
      @padding.try do |padding|
        padding.top + padding.bottom
      end || 0
    end
  end
end
