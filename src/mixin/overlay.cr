module Crysterm
  module Mixin
    # Shared defaults for the floating-overlay widget family (`Dialog`,
    # `SplashScreen`, `ToolTip`, `Menu`, the `ComboBox` drop-down, floating
    # `DockWidget`): at the unstyled floor an overlay carries a
    # structural border so it separates from the content behind it, where a plain
    # content widget doesn't. Included so this one override lives once instead of
    # being copied per overlay class.
    #
    # An active theme still owns the border as usual: any CSS makes the widget
    # `css_styled`, putting the cascade fully in control (see
    # `Mixin::Style#floor_border?`, whose `false` default this replaces).
    module Overlay
      # An overlay carries a structural border at the unstyled floor. A theme can
      # override or remove it via the cascade (see `Mixin::Style#floor_border?`).
      def floor_border? : Bool
        true
      end
    end
  end
end
