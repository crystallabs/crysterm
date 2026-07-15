module Crysterm
  module Mixin
    # Shared defaults for the floating-overlay widget family. At the unstyled
    # floor an overlay carries a structural border, so it separates from the
    # content behind it; an active theme still owns the border via the cascade.
    module Overlay
      # An overlay carries a structural border at the unstyled floor.
      def floor_border? : Bool
        true
      end
    end
  end
end
