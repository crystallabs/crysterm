require "pnggif"

# Crysterm-side reopen of `PNGGIF::Painter`, the `QPainter`-style rasterizer
# that moved into the pnggif shard (REARRANGE R-33). Only the
# `Crysterm::Rectangle` convenience overloads live here — `Rectangle` is
# crysterm vocabulary the shard doesn't know — plus the `Graph::Painter`
# alias that keeps every existing call site compiling unchanged.
module PNGGIF
  class Painter
    # `Rectangle` overload of `#set_window` (`QPainter#setWindow(QRect)`).
    def window=(r : Crysterm::Rectangle) : Nil
      set_window r.x, r.y, r.width, r.height
    end

    # `Rectangle` overload of `#set_viewport` (`QPainter#setViewport(QRect)`).
    def viewport=(r : Crysterm::Rectangle) : Nil
      set_viewport r.x, r.y, r.width, r.height
    end
  end
end

module Crysterm
  class Widget
    module Graph
      alias Painter = PNGGIF::Painter
    end
  end
end
