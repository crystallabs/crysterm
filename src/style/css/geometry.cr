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

      # The unit→cell divisor table. Now lives in `CSS::Length` (shared with
      # `Properties`); kept here as a backwards-compatible alias so existing
      # `Geometry.unit_divisors[...]` call sites/tuning keep working.
      def self.unit_divisors : Hash(String, Float64?)
        Length.divisors
      end

      def self.unit_divisors=(table : Hash(String, Float64?))
        Length.divisors = table
      end

      # Applies a geometry declaration onto *widget*.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      def self.apply(widget : Widget, property : String, value : String) : Nil
        case property
        when "width"  then dimension(value).try { |d| widget.width = d }
        when "height" then dimension(value).try { |d| widget.height = d }
        when "top"    then dimension(value).try { |d| widget.top = d }
        when "left"   then dimension(value).try { |d| widget.left = d }
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

      # Parses a geometry value: a bare integer becomes an `Int32` (cells); a
      # value carrying a CSS unit (`200px`, `0.5em`, ...) is converted to cells
      # through `unit_divisors` (an unmapped/`nil`-mapped unit returns `nil` so
      # the caller ignores it); everything else (`50%`, `center`, `50%-10`, ...)
      # passes through as a `String`, which crysterm's positioning already
      # understands.
      private def self.dimension(value : String) : Int32 | String | Nil
        if value.matches?(Length::PATTERN) || value.to_i?
          Length.to_cells(value) # bare cells or a unit'd length (nil ⇒ ignore)
        else
          value                  # `50%`, `center`, `50%-10`, ... pass through
        end
      end
    end
  end
end
