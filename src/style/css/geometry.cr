module Crysterm
  module CSS
    # Translates CSS geometry/layout declarations onto a `Widget` itself (its
    # position, size and alignment) — as opposed to `Properties`, which targets a
    # `Style`. Geometry is a single per-widget concern, so the cascade applies
    # these only from the `normal` state's winning declarations.
    module Geometry
      PROPERTIES = Set{"width", "height", "top", "left", "right", "bottom",
                       "min-width", "max-width", "min-height", "max-height",
                       "text-align", "spacing"}

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
        when "width"  then resolve_dim(widget, value).try { |d| widget.width = d }
        when "height" then resolve_dim(widget, value).try { |d| widget.height = d }
        when "top"    then resolve_dim(widget, value).try { |d| widget.top = d }
        when "left"   then resolve_dim(widget, value).try { |d| widget.left = d }
          # `right`/`bottom` are offsets in cells only (no `center`/`%` form).
        when "right"  then value.to_i?.try { |cells| widget.right = cells }
        when "bottom" then value.to_i?.try { |cells| widget.bottom = cells }
          # Size constraints are cells only (a bare number or a unit'd length);
          # `%`/unmapped units yield `nil` and are ignored, as `awidth`/`aheight`
          # have no per-frame hook to re-resolve a percentage constraint.
        when "min-width"  then size_cells(widget, value).try { |c| widget.min_width = c }
        when "max-width"  then size_cells(widget, value).try { |c| widget.max_width = c }
        when "min-height" then size_cells(widget, value).try { |c| widget.min_height = c }
        when "max-height" then size_cells(widget, value).try { |c| widget.max_height = c }
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

      # Resolves a `width`/`height`/`top`/`left` value, adding the context the
      # static `dimension` can't supply: a viewport unit (`50vw`) is sized against
      # the widget's screen here and now (ignored if it isn't on a screen yet,
      # since there's nothing to size against).
      private def self.resolve_dim(widget : Widget, value : String) : Int32 | String | Nil
        if Length.viewport?(value)
          widget.screen?.try { |scr| Length.viewport_cells(value, scr.width, scr.height) }
        else
          dimension(value)
        end
      end

      # Resolves a `min-*`/`max-*` size constraint, which must be a cell count.
      # Like `resolve_dim` but with no `%`/keyword pass-through (a constraint has
      # no per-frame hook to re-resolve a percentage).
      private def self.size_cells(widget : Widget, value : String) : Int32?
        if Length.viewport?(value)
          widget.screen?.try { |scr| Length.viewport_cells(value, scr.width, scr.height) }
        else
          Length.to_cells(value)
        end
      end

      # Parses a geometry value: a bare integer becomes an `Int32` (cells); a
      # value carrying a CSS unit (`200px`, `0.5em`, ...) or a `calc(...)` is
      # converted to cells through `unit_divisors` (an unmapped/`nil`-mapped unit,
      # or a `calc` needing layout context, returns `nil` so the caller ignores
      # it); everything else (`50%`, `center`, `50%-10`, ...) passes through as a
      # `String`, which crysterm's positioning already understands.
      private def self.dimension(value : String) : Int32 | String | Nil
        if value.matches?(Length::PATTERN) || value.matches?(Length::CALC) || value.to_i?
          Length.to_cells(value) # bare cells, a unit'd length, or calc (nil ⇒ ignore)
        else
          value # `50%`, `center`, `50%-10`, ... pass through
        end
      end
    end
  end
end
