module Crysterm
  module Mixin
    module Pos
      # NOTE See if this can be unified with something else to reduce code.

      # Number of times object was rendered
      property renders = 0

      # Absolute offsets of the including object's origin.
      #
      # Read-only on purpose: only `Window` answers through these, where `0` is
      # the correct constant — a surface's origin is always 0. On `Widget` they
      # are shadowed by the computed `#aleft`/`#atop`/`#aright`/`#abottom`.
      # Non-nilable so `window.aleft` and `widget.aleft` agree in type — the
      # nilable spelling forced `(aleft || 0)` on every mixed call site for a
      # value that was never actually nil.
      getter aleft : Int32 = 0

      # :ditto:
      getter atop : Int32 = 0

      # :ditto:
      getter aright : Int32 = 0

      # :ditto:
      getter abottom : Int32 = 0

      # Last rendered position. Never retain it past the current frame — the
      # render path reuses the instance in place.
      #
      # The setter is `protected`: only the render/layout pipeline may assign a
      # rendered rectangle.
      getter lpos : RenderedGeometry? = nil

      # :nodoc:
      protected setter lpos
    end
  end
end
