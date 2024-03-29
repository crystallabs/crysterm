module Crysterm
  class Widget
    # Widget decorations

    # Returns computed content offset from left
    def ileft
      (style.border.try(&.left) || 0) + style.padding.left
    end

    # Returns computed content offset from top
    def itop
      (style.border.try(&.top) || 0) + style.padding.top
    end

    # Returns computed content offset from right
    def iright
      (style.border.try(&.right) || 0) + style.padding.right
    end

    # Returns computed content offset from bottom
    def ibottom
      (style.border.try(&.bottom) || 0) + style.padding.bottom
    end

    # Returns summed amount of content offset from left and right
    def iwidth
      # return (style.border
      #   ? ((style.border.left ? 1 : 0) + (style.border.right ? 1 : 0)) : 0)
      #   + style.padding.left + style.padding.right
      (style.border.try { |border| border.left + border.right } || 0) +
        (style.padding.try { |p| p.left + p.right })
    end

    # Returns summed amount of content offset from top and bottom
    def iheight
      # return (style.border
      #   ? ((style.border.top ? 1 : 0) + (style.border.bottom ? 1 : 0)) : 0)
      #   + style.padding.top + style.padding.bottom
      (style.border.try { |border| border.top + border.bottom } || 0) +
        (style.padding.try { |p| p.top + p.bottom })
    end
  end
end
