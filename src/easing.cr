module Crysterm
  # Easing curves mapping linear progress (`0.0..1.0`) to eased progress
  # (`0.0..1.0`). `Linear` is the identity; the rest accelerate (`In`),
  # decelerate (`Out`), or both (`InOut`).
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
      # Integer powers are written as explicit multiplication: `x ** 2`/`x ** 3`
      # on a `Float64` compile to a `LibM.pow` call, and `#apply` runs once per
      # active tween every frame during any transition/animation/fade.
      case self
      in Easing::Linear     then t
      in Easing::InQuad     then t * t
      in Easing::OutQuad    then t * (2.0 - t)
      in Easing::InOutQuad  then t < 0.5 ? 2.0 * t * t : (u = -2.0 * t + 2.0; 1.0 - u * u / 2.0)
      in Easing::InCubic    then t * t * t
      in Easing::OutCubic   then (u = 1.0 - t; 1.0 - u * u * u)
      in Easing::InOutCubic then t < 0.5 ? 4.0 * t * t * t : (u = -2.0 * t + 2.0; 1.0 - u * u * u / 2.0)
      in Easing::InOutSine  then -(Math.cos(Math::PI * t) - 1.0) / 2.0
      end
    end
  end
end
