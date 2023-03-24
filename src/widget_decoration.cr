module Crysterm
  class Widget
    # Widget decorations

    @auto_padding = true

    # Returns computed content offset from left
    def ileft
      (style.border.try(&.left) || 0) + (style.padding.try(&.left) || 0)
    end

    # Returns computed content offset from top
    def itop
      (style.border.try(&.top) || 0) + (style.padding.try(&.top) || 0)
    end

    # Returns computed content offset from right
    def iright
      (style.border.try(&.right) || 0) + (style.padding.try(&.right) || 0)
    end

    # Returns computed content offset from bottom
    def ibottom
      (style.border.try(&.bottom) || 0) + (style.padding.try(&.bottom) || 0)
    end
  end
end
