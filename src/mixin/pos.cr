module Crysterm
  module Mixin
    module Pos
      # NOTE See if this can be unified with something else to reduce code.

      # Number of times object was rendered
      property renders = 0

      # Absolute offsets of the including object's origin, `nil` meaning "no
      # offset" (`widget_position.cr` reads them as `parent.aleft || 0`).
      #
      # Read-only on purpose: only `Window` answers through these, where `nil` is
      # the correct constant — a surface's origin is always 0. On `Widget` they
      # are shadowed by the computed `#aleft`/`#atop`/`#aright`/`#abottom` in
      # `widget_position.cr`, so a writer here would be settable but never read.
      getter aleft : Int32? = nil

      # :ditto:
      getter atop : Int32? = nil

      # :ditto:
      getter aright : Int32? = nil

      # :ditto:
      getter abottom : Int32? = nil

      # Last rendered position
      property lpos : RenderedGeometry? = nil
    end
  end
end
