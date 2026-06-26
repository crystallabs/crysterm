module Crysterm
  class Widget
    module Media
      # How an image is fit into a box whose aspect ratio differs from the
      # image's — shared by every backend so the behaviour is consistent.
      enum Fit
        Stretch # fill the box exactly, distorting aspect ratio (default)
        Contain # scale to fit inside the box, letterboxing the remainder
        Cover   # scale to fill the box, cropping the overflow
        None    # draw at the source's native 1:1 size, centered (cropped if larger than the box)

        # Lays an image of *sw*×*sh* into a *bw*×*bh* box, returning the drawn
        # size and top-left offset `{dw, dh, ox, oy}` (offsets are negative for
        # `Cover`/`None`, where the image is larger than the box and gets cropped).
        def layout(bw : Int32, bh : Int32, sw : Int32, sh : Int32) : Tuple(Int32, Int32, Int32, Int32)
          # 1:1 — keep the source's own pixel size, centered in the box.
          return {sw, sh, (bw - sw) // 2, (bh - sh) // 2} if none? && sw > 0 && sh > 0
          return {bw, bh, 0, 0} if stretch? || sw <= 0 || sh <= 0 || bw <= 0 || bh <= 0
          ar = sw.to_f / sh.to_f
          box_ar = bw.to_f / bh.to_f
          # Pin height (derive width) when the box is "wider" than the image for
          # Contain, or "taller" for Cover; pin width otherwise.
          pin_height = contain? ? (box_ar > ar) : (box_ar < ar)
          if pin_height
            dh = bh
            dw = (bh * ar).round.to_i
          else
            dw = bw
            dh = (dw / ar).round.to_i
          end
          dw = 1 if dw < 1
          dh = 1 if dh < 1
          {dw, dh, (bw - dw) // 2, (bh - dh) // 2}
        end
      end
    end
  end
end
