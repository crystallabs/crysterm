require "./base"

module Crysterm
  class Widget
    # Abstract base for the **external-overlay** image backends — those whose
    # pixels are painted by a separate helper process in its own window placed
    # over the terminal, owned by neither Crysterm's cell grid nor the terminal
    # emulator (`Image::Overlay` via `w3mimgdisplay`, `Image::Ueberzug` via
    # `ueberzug`).
    #
    # These are inherently static: the helper shows one image, so they don't
    # implement the render-driven animation loop. `animate?` is false and `#play`
    # routes through `Image::Base#unsupported`, so asking one to animate follows
    # the `image.unsupported` policy (error or ignore) instead of silently doing
    # nothing.
    #
    # The unified `fit` contract knob is advisory here: each helper has its own,
    # richer scaling control — `Image::Overlay#stretch`/`#center`,
    # `Image::Ueberzug#scaler` — which is what actually takes effect.
    abstract class Image::External < Image::Base
      # External overlays are static; never auto-animate.
      @animate = false

      # Animation is not supported by an external-helper overlay.
      def play
        unsupported "animation"
      end
    end
  end
end
