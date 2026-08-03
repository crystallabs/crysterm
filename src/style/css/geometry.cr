module Crysterm
  class Widget
    # Pristine, pre-CSS snapshot of every widget property `CSS::Geometry` can
    # write. Captured once, just before the cascade first applies a geometry
    # declaration to this widget, and restored by the cascade's reset pass — so
    # a geometry rule that stops matching (an `@media` condition, a removed
    # class) reverts the widget instead of sticking forever. The `Style` side of
    # the same contract is `css_base_styles`.
    record CssBaseGeometry,
      width : Dim | Int32 | String?,
      height : Dim | Int32 | String?,
      top : Dim | Int32 | String?,
      left : Dim | Int32 | String?,
      right : Dim | Int32 | String?,
      bottom : Dim | Int32 | String?,
      min_width : Dim | Int32 | String?,
      max_width : Dim | Int32 | String?,
      min_height : Dim | Int32 | String?,
      max_height : Dim | Int32 | String?,
      align : Tput::AlignFlag,
      gap : Int32?,
      layout_chrome : Bool,
      fixed : Bool,
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
        gap: layout.try(&.spacing),
        layout_chrome: @layout_chrome, fixed: @fixed,
        password_character: as?(Widget::LineEdit).try(&.password_character))
    end

    # Restores the pristine pre-CSS geometry (no-op when CSS never wrote any).
    # Runs through the public change-guarded setters, so a changed value marks
    # dirty / emits Move/Resize like any programmatic assignment.
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
      self.layout_chrome = snap.layout_chrome
      self.fixed = snap.fixed
      snap.gap.try { |g| layout.try(&.spacing=(g)) }
      snap.password_character.try { |c| as?(Widget::LineEdit).try(&.password_character=(c)) }
    end

    # Drops the pristine geometry snapshot so it is recaptured from the current
    # values on the next cascade. Call after deliberately changing a widget's
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
      PROPERTIES = Set{"position",
                       "width", "height", "top", "left", "right", "bottom",
                       "min-width", "max-width", "min-height", "max-height",
                       "text-align", "vertical-align", "gap", "spacing",
                       "lineedit-password-character"}

      # Whether *property* is a geometry property handled here.
      def self.handles?(property : String) : Bool
        PROPERTIES.includes? property
      end

      # Applies a geometry declaration onto *widget*.
      def self.apply(widget : Widget, property : String, value : String) : Nil
        case property
        when "position"
          # CSS's flow-vs-out-of-flow distinction, which Crysterm already has
          # both halves of:
          #
          # * `static` — arranged by the parent's `Layout` engine (the default).
          # * `absolute` — taken out of the layout flow (`layout_chrome`) and
          #   placed by its own `top`/`left`/`right`/`bottom`/percentages against
          #   the parent, which is always this widget's containing block. Still
          #   painted, just not measured into a slot. In a container with no
          #   layout engine (`Layout::Manual`) every child is already placed this
          #   way, so there `static` and `absolute` coincide — as in CSS.
          # * `fixed` — additionally pinned against a scrolling ancestor
          #   (`Widget#fixed?`), i.e. it does not scroll away with the content.
          #   CSS anchors `fixed` to the viewport; "does not scroll" is the part
          #   of that which a cell grid can honor.
          #
          # `relative` is accepted as in-flow (its defining CSS trait) but the
          # post-placement offset is not applied — the layout engines position
          # their slots and have no shift-after-arrange step. `sticky` has no
          # mapping and is ignored.
          case Case.fold_keyword(value.strip)
          when "static", "relative"
            widget.layout_chrome = false
            widget.fixed = false
          when "absolute"
            widget.layout_chrome = true
            widget.fixed = false
          when "fixed"
            widget.layout_chrome = true
            widget.fixed = true
          end
          # All four edges resolve identically: `#right`/`#bottom` accept the
          # same forms as `#left`/`#top`. `dim_guard` drops a String the widget
          # setters can't parse (CSS semantics: an invalid value is ignored —
          # the setters raise, which must never escape a cascade pass).
        when "width"  then resolve_dim(value, size: true).try { |d| dim_guard(d, size: true).try { |v| widget.width = v } }
        when "height" then resolve_dim(value, vertical: true, size: true).try { |d| dim_guard(d, size: true).try { |v| widget.height = v } }
        when "top"    then resolve_dim(value, vertical: true).try { |d| dim_guard(d).try { |v| widget.top = v } }
        when "left"   then resolve_dim(value).try { |d| dim_guard(d).try { |v| widget.left = v } }
        when "right"  then resolve_dim(value).try { |d| dim_guard(d).try { |v| widget.right = v } }
        when "bottom" then resolve_dim(value, vertical: true).try { |d| dim_guard(d).try { |v| widget.bottom = v } }
          # Size constraints take the same forms as `width`/`height`, `%`
          # included — the widget stores the spec and resolves it against the
          # parent inside its clamp, so no per-frame hook is needed here.
        when "min-width"  then size_constraint(value) { |v| widget.min_width = v }
        when "max-width"  then size_constraint(value) { |v| widget.max_width = v }
        when "min-height" then size_constraint(value, vertical: true) { |v| widget.min_height = v }
        when "max-height" then size_constraint(value, vertical: true) { |v| widget.max_height = v }
        when "text-align"
          # CSS keyword values are case-insensitive, so fold before matching;
          # an unrecognized value leaves the alignment unchanged. `text-align` is
          # a *horizontal*-axis property, so only the horizontal bits are
          # replaced — assigning the bare flag would clear a widget's
          # `VCenter`/`Bottom` (`Tput::AlignFlag::Top` is `0x20`, not zero, so
          # even the default vertical alignment is a real bit that would be lost).
          TextAlign.align_flag(Case.fold_keyword(value.strip)).try do |f|
            widget.align = (widget.align & ~Tput::AlignFlag::Horizontal_Mask) | f
          end
        when "vertical-align"
          # The vertical mirror of `text-align`. CSS's own `vertical-align`
          # aligns inline boxes against a baseline, which a cell grid has no
          # analog for; the terminal reading — where in the box the content
          # sits — is the useful one, and `top`/`middle`/`bottom` are spelled
          # exactly as in CSS.
          TextAlign.valign_flag(Case.fold_keyword(value.strip)).try do |f|
            widget.align = (widget.align & ~Tput::AlignFlag::Vertical_Mask) | f
          end
        when "spacing", "gap"
          # Inter-child spacing of the widget's layout: CSS's `gap`, spelled
          # `spacing` in Qt — both accepted. Engines that don't honor it ignore
          # the value; no-op with no layout.
          Length.to_cells(value).try { |cells| widget.layout.try(&.spacing=(cells)) if cells >= 0 }
        when "lineedit-password-character"
          # Mask character for a censored `LineEdit` (Qt's
          # `lineedit-password-character`). No-op on any other widget type.
          widget.as?(Widget::LineEdit).try do |t|
            password_char(value).try { |c| t.password_character = c }
          end
        end
      end

      # Pre-parses a geometry value bound for the `Dim`-normalizing widget
      # setters: an `Int32` passes, a parseable `String` becomes its `Dim`
      # (parsed here once, in *size*/position context), and an unparseable one
      # returns `nil` so the caller skips the declaration instead of letting
      # the setter's `ArgumentError` kill the cascade.
      private def self.dim_guard(v : Int32 | String, size : Bool = false) : Dim | Int32?
        case v
        in Int32  then v
        in String then Dim.parse?(v, size: size)
        end
      end

      # Resolves a `lineedit-password-character` value to a `Char`. Qt themes
      # give a Unicode code point as a bare number (e.g. `9679` ⇒ ●); a literal
      # (optionally quoted) value uses its first character. `nil` if empty, an
      # out-of-range code point, or `none` (a mask char can't be omitted).
      private def self.password_char(value : String) : Char?
        Properties.char_value(value)
      end

      # Resolves a `width`/`height`/`top`/`left` value. A viewport unit (`50vw`)
      # passes through as its *string*, so the positioner re-resolves it against
      # the window every frame and tracks terminal resize; everything else
      # resolves statically.
      private def self.resolve_dim(value : String, vertical : Bool = false, size : Bool = false) : Int32 | String?
        # Only a viewport unit contains a 'v'; this allocation-free scan keeps
        # the VIEWPORT regex off every plain width/height/top/left value.
        (maybe_viewport?(value) && Length.viewport?(value)) ? value : dimension(value, vertical, size)
      end

      # Whether *value* might be a viewport unit — a cheap gate before the
      # `VIEWPORT` regex. Matches `v`/`V` in either case (`50VW`).
      private def self.maybe_viewport?(value : String) : Bool
        value.includes?('v') || value.includes?('V')
      end

      # Resolves a `min-*`/`max-*` size constraint. Identical to `resolve_dim`
      # in size context — the widget stores the unresolved spec and its
      # `clamp_awidth`/`clamp_aheight` resolves a `%`/`Dim` against the parent's
      # content area, the same base a percentage `width` uses, so `min-width:
      # 50%` and `width: 50%` measure against the same thing. `none` clears the
      # constraint, per CSS's `max-width: none`.
      private def self.size_constraint(value : String, vertical : Bool = false, &block : (Dim | Int32 | String?) -> _) : Nil
        # `none` clears the constraint (CSS's `max-width: none`). Yielded
        # explicitly rather than returned, since `nil` is also how the parse
        # failures below say "drop this declaration".
        if Case.fold_keyword(value.strip) == "none"
          block.call nil
          return
        end
        resolve_dim(value, vertical, size: true).try { |d| dim_guard(d, size: true).try { |v| block.call v } }
      end

      # Parses a geometry value: a bare integer becomes an `Int32` (cells); a
      # value carrying a CSS unit (`200px`, `0.5em`, ...) or a `calc(...)` is
      # converted to cells through `unit_divisors`; everything else (`50%`,
      # `center`, `50%-10`, ...) passes through as a `String`, which crysterm's
      # positioning already understands.
      private def self.dimension(value : String, vertical : Bool = false, size : Bool = false) : Int32 | String?
        if cells = Length.to_cells(value, vertical)
          # A *size* is the widget's whole extent: a positive sub-cell length
          # (`0.2em`, `2px`) rounding down to 0 would collapse the widget to
          # nothing, so clamp it up to the smallest representable size. This is
          # the deliberate opposite of a sub-cell *border* width, which resolves
          # to no border (see `Properties.border_cells?`): a dropped hairline
          # frame still leaves the widget itself, a dropped size does not.
          # Positions (`top`/`left`/...) keep the plain rounding — a 0-cell
          # offset is a legitimate result there.
          cells = 1 if size && cells <= 0 && (f = Length.to_cells_f(value, vertical)) && f > 0
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
