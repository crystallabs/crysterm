module Crysterm
  # Easing curves mapping linear progress (`0.0..1.0`) to eased progress
  # (`0.0..1.0`). `Linear` is the identity; the rest accelerate (`In`),
  # decelerate (`Out`), or both (`InOut`).
  #
  # Independent of any clock: `FrameClock` tweens read it, and the CSS layer
  # maps `transition`/`animation` timing-function keywords onto it.
  enum Easing
    Linear
    InQuad
    OutQuad
    InOutQuad
    InCubic
    OutCubic
    InOutCubic
    InOutSine

    # Applies the curve to *t* (clamped `0.0..1.0` by the caller).
    def apply(t : Float64) : Float64
      case self
      in Easing::Linear     then t
      in Easing::InQuad     then t * t
      in Easing::OutQuad    then t * (2.0 - t)
      in Easing::InOutQuad  then t < 0.5 ? 2.0 * t * t : 1.0 - (-2.0 * t + 2.0) ** 2 / 2.0
      in Easing::InCubic    then t ** 3
      in Easing::OutCubic   then 1.0 - (1.0 - t) ** 3
      in Easing::InOutCubic then t < 0.5 ? 4.0 * t ** 3 : 1.0 - (-2.0 * t + 2.0) ** 3 / 2.0
      in Easing::InOutSine  then -(Math.cos(Math::PI * t) - 1.0) / 2.0
      end
    end
  end
end
