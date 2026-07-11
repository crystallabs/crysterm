module Crysterm
  class Widget
    # Pristine, pre-CSS snapshot of every widget property `CSS::Geometry` can
    # write (see `Geometry::PROPERTIES`). Captured once, just before the cascade
    # first applies a geometry declaration to this widget, and restored by the
    # cascade's reset pass — so a geometry rule that stops matching (an `@media`
    # condition, a removed class) reverts the widget instead of sticking
    # forever. The `Style` side of the same contract is `css_base_styles`.
    record CssBaseGeometry,
      width : Int32 | String | Nil,
      height : Int32 | String | Nil,
      top : Int32 | String | Nil,
      left : Int32 | String | Nil,
      right : Int32?,
      bottom : Int32?,
      min_width : Int32?,
      max_width : Int32?,
      min_height : Int32?,
      max_height : Int32?,
      align : Tput::AlignFlag,
      gap : Int32?,
      password_character : Char?

    # :ditto: — `nil` until CSS ever touches this widget's geometry, so both
    # capture and restore stay free for the common geometry-rule-less widget.
    @css_base_geometry : CssBaseGeometry?

    # Captures the pristine geometry snapshot (no-op once captured). Called by
    # the cascade immediately before the first geometry declaration is applied.
    def capture_css_base_geometry : Nil
      return if @css_base_geometry
      @css_base_geometry = CssBaseGeometry.new(
        width: @width, height: @height, top: @top, left: @left,
        right: @right, bottom: @bottom,
        min_width: @min_width, max_width: @max_width,
        min_height: @min_height, max_height: @max_height,
        align: @align,
        gap: layout.try(&.gap),
        password_character: as?(Widget::LineEdit).try(&.password_character))
    end

    # Restores the pristine pre-CSS geometry (no-op when CSS never wrote any).
    # Runs through the public change-guarded setters, so an unchanged value
    # costs a comparison and a changed one marks dirty / emits Move/Resize like
    # any programmatic assignment.
    def restore_css_base_geometry : Nil
      snap = @css_base_geometry
      return unless snap
      self.width = snap.width
      self.height = snap.height
      self.top = snap.top
      self.left = snap.left
      self.right = snap.right
      self.bottom = snap.bottom
      self.min_width = snap.min_width
      self.max_width = snap.max_width
      self.min_height = snap.min_height
      self.max_height = snap.max_height
      self.align = snap.align
      snap.gap.try { |g| layout.try(&.gap=(g)) }
      snap.password_character.try { |c| as?(Widget::LineEdit).try(&.password_character=(c)) }
    end

    # Drops the pristine geometry snapshot so it is recaptured from the current
    # values on the next cascade — the geometry counterpart of
    # `#reset_css_base_styles`. Call after deliberately changing a widget's
    # programmatic geometry while CSS geometry rules are active.
    def reset_css_base_geometry : Nil
      @css_base_geometry = nil
    end
  end

  module CSS
    # Translates CSS geometry/layout declarations onto a `Widget` itself (its
    # position, size and alignment) — as opposed to `Properties`, which targets
    # a `Style`. Geometry is a single per-widget concern, so the cascade
    # applies these only from the `normal` state's winning declarations.
    module Geometry
      PROPERTIES = Set{"width", "height", "top", "left", "right", "bottom",
                       "min-width", "max-width", "min-height", "max-height",
                       "text-align", "spacing", "lineedit-password-character"}

      # Whether *property* is a geometry property handled here.
      def self.handles?(property : String) : Bool
        PROPERTIES.includes? property
      end

      # The unit→cell divisor table, which lives in `CSS::Length` (shared with
      # `Properties`). Kept here as a backwards-compatible alias so existing
      # `Geometry.unit_divisors[...]` call sites/tuning keep working.
      def self.unit_divisors : Hash(String, Float64?)
        Length.divisors
      end

      def self.unit_divisors=(table : Hash(String, Float64?))
        Length.divisors = table
      end

      # Applies a geometry declaration onto *widget*.
      #
      def self.apply(widget : Widget, property : String, value : String) : Nil
        case property
        when "width"  then resolve_dim(value).try { |d| widget.width = d }
        when "height" then resolve_dim(value, vertical: true).try { |d| widget.height = d }
        when "top"    then resolve_dim(value, vertical: true).try { |d| widget.top = d }
        when "left"   then resolve_dim(value).try { |d| widget.left = d }
          # `right`/`bottom` are offsets in cells only (no `center`/`%` form).
        when "right"  then value.to_i?.try { |cells| widget.right = cells }
        when "bottom" then value.to_i?.try { |cells| widget.bottom = cells }
          # Size constraints are cells only; `%`/unmapped units yield `nil`
          # and are ignored (no per-frame hook to re-resolve a percentage).
        when "min-width"  then size_cells(widget, value).try { |c| widget.min_width = c }
        when "max-width"  then size_cells(widget, value).try { |c| widget.max_width = c }
        when "min-height" then size_cells(widget, value, vertical: true).try { |c| widget.min_height = c }
        when "max-height" then size_cells(widget, value, vertical: true).try { |c| widget.max_height = c }
        when "text-align"
          # CSS keyword values are case-insensitive, so fold before matching
          # (see `Properties`) — otherwise a capitalized value (common in Qt
          # themes) would silently leave the alignment unchanged. Routed through
          # the shared string→flag resolver; an unrecognized value yields `nil`
          # and leaves the alignment unchanged.
          TextHtml.align_flag(Case.fold_keyword(value.strip)).try { |f| widget.align = f }
        when "spacing"
          # Inter-child spacing of the widget's layout (Qt's layout `spacing`).
          # `gap` lives on the `Layout` base; engines that don't honor it (the
          # flow layouts) simply ignore the value. No-op without a layout.
          value.to_i?.try { |cells| widget.layout.try(&.gap=(cells)) }
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
      # (optionally quoted) value uses its first character. `nil` if empty, an
      # out-of-range code point, or `none` (a mask char can't be omitted).
      # Shares `Properties.parse_char` with the `glyph` property family.
      private def self.password_char(value : String) : Char?
        Properties.parse_char(value).try { |c| c unless c == Glyphs::NONE }
      end

      # Resolves a `width`/`height`/`top`/`left` value. A viewport unit (`50vw`)
      # passes through as its *string*, so the positioner re-resolves it against
      # the window every frame and tracks terminal resize (see
      # `Widget#resolve_dimension`); everything else resolves statically via
      # `dimension`.
      private def self.resolve_dim(value : String, vertical : Bool = false) : Int32 | String | Nil
        # Only a viewport unit contains a 'v'; this allocation-free scan keeps
        # the VIEWPORT regex off every plain width/height/top/left value.
        (maybe_viewport?(value) && Length.viewport?(value)) ? value : dimension(value, vertical)
      end

      # Whether *value* might be a viewport unit — a cheap gate before the
      # `VIEWPORT` regex. Matches `v`/`V` in either case (`50VW`).
      private def self.maybe_viewport?(value : String) : Bool
        value.includes?('v') || value.includes?('V')
      end

      # Resolves a `min-*`/`max-*` size constraint, which must be a cell count.
      # Like `resolve_dim`, but a constraint has no per-frame hook to re-resolve,
      # so a viewport unit is sized against the window once, here and now
      # (`nil` if not on a window yet); `%` has no cell mapping at all.
      private def self.size_cells(widget : Widget, value : String, vertical : Bool = false) : Int32?
        # If the widget isn't mounted, or it's some other 'v' string, fall
        # through to `to_cells` (drops a viewport unit to `nil`).
        if maybe_viewport?(value)
          if (scr = widget.window?) && (cells = Length.viewport_cells(value, scr.awidth, scr.aheight))
            return cells
          end
        end
        Length.to_cells(value, vertical)
      end

      # Parses a geometry value: a bare integer becomes an `Int32` (cells); a
      # value carrying a CSS unit (`200px`, `0.5em`, ...) or a `calc(...)` is
      # converted to cells through `unit_divisors`; everything else (`50%`,
      # `center`, `50%-10`, ...) passes through as a `String`, which crysterm's
      # positioning already understands.
      private def self.dimension(value : String, vertical : Bool = false) : Int32 | String | Nil
        if cells = Length.to_cells(value, vertical)
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
