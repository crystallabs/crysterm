module Crysterm
  module CSS
    # Translates CSS geometry/layout declarations onto a `Widget` itself (its
    # position, size and alignment) — as opposed to `Properties`, which targets a
    # `Style`. Geometry is a single per-widget concern, so the cascade applies
    # these only from the `normal` state's winning declarations.
    module Geometry
      PROPERTIES = Set{"width", "height", "top", "left", "right", "bottom", "text-align", "spacing"}

      # Whether *property* is a geometry property handled here.
      def self.handles?(property : String) : Bool
        PROPERTIES.includes? property
      end

      # Applies a geometry declaration onto *widget*.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      def self.apply(widget : Widget, property : String, value : String) : Nil
        case property
        when "width"  then widget.width = dimension(value)
        when "height" then widget.height = dimension(value)
        when "top"    then widget.top = dimension(value)
        when "left"   then widget.left = dimension(value)
          # `right`/`bottom` are offsets in cells only (no `center`/`%` form).
        when "right"  then value.to_i?.try { |cells| widget.right = cells }
        when "bottom" then value.to_i?.try { |cells| widget.bottom = cells }
        when "text-align"
          case value
          when "left"   then widget.align = Tput::AlignFlag::Left
          when "center" then widget.align = Tput::AlignFlag::HCenter
          when "right"  then widget.align = Tput::AlignFlag::Right
          end
        when "spacing"
          # Inter-child spacing of the widget's layout (Qt's layout `spacing`).
          # `gap` lives on the `Layout` base; engines that don't honor it (the
          # flow layouts) simply ignore the value. No-op without a layout.
          value.to_i?.try { |cells| widget.layout.try { |l| l.gap = cells } }
        end
      end

      # Parses a geometry value: a bare integer becomes an `Int32` (cells);
      # everything else (`50%`, `center`, `50%-10`, ...) passes through as a
      # `String`, which crysterm's positioning already understands.
      private def self.dimension(value : String) : Int32 | String
        value.to_i? || value
      end
    end
  end
end
