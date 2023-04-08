module Crysterm
  class Screen
    # For compatibility with widgets. But, as a side-effect, screens can have padding!
    # If you define widget at position (0,0), that will be counted after padding.
    # (We leave this at nil for no padding. If we used Padding.new that'd create a
    # 1 cell padding by default.)
    property padding = Padding.default

    # Amount of space taken by decorations on the left side, to be subtracted from widget's total width
    def ileft
      @padding.left
    end

    # Amount of space taken by decorations on top, to be subtracted from widget's total height
    def itop
      @padding.top
    end

    # Amount of space taken by decorations on the right side, to be subtracted from widget's total width
    def iright
      @padding.right
    end

    # Amount of space taken by decorations on bottom, to be subtracted from widget's total height
    def ibottom
      @padding.bottom
    end

    # Returns current screen width.
    def iwidth
      p = @padding
      p.left + p.right
    end

    # Returns current screen height.
    def iheight
      p = @padding
      p.top + p.bottom
    end
  end
end
