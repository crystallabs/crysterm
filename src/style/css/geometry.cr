module Crysterm
  module CSS
    # Translates CSS geometry/layout declarations onto a `Widget` itself (its
    # position, size and alignment) — as opposed to `Properties`, which targets a
    # `Style`. Geometry is a single per-widget concern, so the cascade applies
    # these only from the `normal` state's winning declarations.
    module Geometry
      PROPERTIES = Set{"width", "height", "top", "left", "right", "bottom",
                       "min-width", "max-width", "min-height", "max-height",
                       "text-align", "spacing", "lineedit-password-character"}

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
        when "width"  then resolve_dim(value).try { |d| widget.width = d }
        when "height" then resolve_dim(value).try { |d| widget.height = d }
        when "top"    then resolve_dim(value).try { |d| widget.top = d }
        when "left"   then resolve_dim(value).try { |d| widget.left = d }
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
        when "lineedit-password-character"
          # Mask character for a censored `LineEdit` (Qt's
          # `lineedit-password-character`). No-op on any other widget type.
          widget.as?(Widget::LineEdit).try do |t|
            password_char(value).try { |c| t.password_character = c }
          end
        end
      end

      # Resolves a `lineedit-password-character` value to a `Char`. Qt themes
      # give a Unicode code point as a bare number (e.g. `9679` ⇒ ●); a literal
      # (optionally quoted) value uses its first character. `nil` if empty or an
      # out-of-range code point.
      private def self.password_char(value : String) : Char?
        v = value.strip
        if cp = v.to_i?
          return (cp.chr rescue nil)
        end
        v = v.strip('"').strip('\'')
        v.empty? ? nil : v[0]
      end

      # Resolves a `width`/`height`/`top`/`left` value. A viewport unit (`50vw`)
      # passes through as its *string*, so the positioner re-resolves it against
      # the screen on every frame and it tracks terminal resize (see
      # `Widget#resolve_dimension`); everything else resolves to a static value
      # now via `dimension`.
      private def self.resolve_dim(value : String) : Int32 | String | Nil
        # Only a viewport unit contains a 'v'; this allocation-free byte scan keeps
        # the VIEWPORT regex off every plain width/height/top/left value.
        (value.includes?('v') && Length.viewport?(value)) ? value : dimension(value)
      end

      # Resolves a `min-*`/`max-*` size constraint, which must be a cell count.
      # Like `resolve_dim`, but a constraint has no per-frame hook to re-resolve,
      # so a viewport unit is sized against the screen once, here and now (`nil`
      # if the widget isn't on a screen yet), and `%` has no cell mapping at all.
      private def self.size_cells(widget : Widget, value : String) : Int32?
        # A viewport unit ('v' present) sizes against the screen once, here and
        # now — a single `viewport_cells` both detects and resolves it (no extra
        # `viewport?` regex pass). If the widget isn't mounted yet, or it's some
        # other 'v' string, fall through to `to_cells` (which drops a viewport
        # unit to `nil`, i.e. ignored).
        if value.includes?('v')
          if (scr = widget.screen?) && (cells = Length.viewport_cells(value, scr.awidth, scr.aheight))
            return cells
          end
        end
        Length.to_cells(value)
      end

      # Parses a geometry value: a bare integer becomes an `Int32` (cells); a
      # value carrying a CSS unit (`200px`, `0.5em`, ...) or a `calc(...)` is
      # converted to cells through `unit_divisors`; everything else (`50%`,
      # `center`, `50%-10`, ...) passes through as a `String`, which crysterm's
      # positioning already understands.
      #
      # Resolve *once* (the old code pre-matched the same regexes that `to_cells`
      # re-runs): a non-`nil` result is the cell count (`0` included). On `nil`,
      # one regex pass tells an unmappable length (`3cm`, a `%`-bearing `calc`) —
      # which we ignore — apart from a positioner string, which we pass through.
      private def self.dimension(value : String) : Int32 | String | Nil
        if cells = Length.to_cells(value)
          cells
        elsif value.matches?(Length::PATTERN) || value.matches?(Length::CALC)
          nil # recognized length form but no cell mapping ⇒ ignore
        else
          value # `50%`, `center`, `50%-10`, ... pass through
        end
      end
    end
  end
end
