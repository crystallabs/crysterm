module Crysterm
  module Overlay
    # Shared defaults for the floating-overlay widget family. At the unstyled
    # floor an overlay carries a structural border, so it separates from the
    # content behind it; an active theme still owns the border via the cascade.
    #
    # Lives in the `Overlay` family (not `Mixin`): the old `Mixin::Overlay`
    # name collided with `Crysterm::Overlay` itself.
    module Floor
      # An overlay carries a structural border at the unstyled floor.
      def floor_border? : Bool
        true
      end
    end
  end
end
