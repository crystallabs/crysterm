module Crysterm
  module CSS
    # Translates CSS declarations (real CSS property names) onto a `Style`.
    #
    # Property names that have a clean CSS analog use that analog (`color`,
    # `background-color`, `font-weight`, ...). Where there is no standard CSS
    # property, a pragmatic spelling is chosen — e.g. reverse-video maps to
    # `text-decoration: reverse`. A few crysterm-only attributes (the fill chars)
    # are still unexposed and remain settable through the programmatic `Style`
    # API until an honest CSS spelling is chosen.
    module Properties
      # Applies a single `property: value` declaration onto *style*. Unknown
      # properties are ignored, matching CSS's forgiving behavior.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      def self.apply(style : Style, property : String, value : String) : Nil
        return apply_border(style, property, value) if property.starts_with?("border")

        case property
        when "color"
          style.fg = ColorValue.resolve(value, style.fg)
        when "background-color"
          style.bg = ColorValue.resolve(value, style.fg)
        when "alternate-background-color"
          # Background of every other row in a `Table`/`ListTable` with
          # `alternate_rows` on (Qt's `alternate-background-color`). Lives in the
          # `alternate_row` sub-style.
          style.alternate_background = ColorValue.resolve(value, style.fg)
        when "gridline-color"
          # Color of a table's internal gridlines (Qt's `gridline-color`).
          style.gridline_color = ColorValue.resolve(value, style.fg)
        when "selection-color", "selection-background-color"
          # Selected-item colors. These target a *different* `Style` (the
          # `:selected` state), so they can't be applied to *this* style here —
          # the cascade rewrites them onto the selected state (see
          # `Cascade#selection_entries`). Named here only so they're not treated
          # as unknown; the value is consumed there.
        when "background"
          # `background` shorthand: pull the color out (image/position/repeat
          # parts are meaningless in a terminal and ignored).
          parse_background_color(value, style.fg).try { |color| style.bg = color }
        when "font"
          # `font` shorthand: only the weight/style words mean anything here;
          # presence sets the attribute, absence resets it (shorthand semantics).
          words = value.split
          style.bold = words.includes?("bold")
          style.italic = words.includes?("italic")
        when "font-weight"
          style.bold = bool_keyword(value, on: "bold", off: "normal", current: style.bold?)
        when "font-style"
          style.italic = bool_keyword(value, on: "italic", off: "normal", current: style.italic?)
        when "text-decoration"
          words = value.split
          style.underline = words.includes?("underline")
          style.blink = words.includes?("blink")
          # `line-through` maps to the terminal's strikethrough attribute
          # (`Style#strike` / SGR 9). Shorthand semantics: absent -> off.
          style.strike = words.includes?("line-through")
          # `reverse` (alias `inverse`) maps to the terminal's reverse-video
          # attribute — the classic TUI selection/highlight look, which has no
          # standard CSS spelling. Shorthand semantics: absent -> off.
          style.reverse = words.includes?("reverse") || words.includes?("inverse")
        when "visibility"
          style.visible = (value != "hidden")
        when "display"
          style.visible = (value != "none")
        when "opacity"
          value.to_f?.try { |num| style.alpha = num }
        when "tab-size"
          style.tab_size = cells(value)
        when "box-shadow"
          style.shadow = parse_box_shadow(value)
        when "tint"
          parse_tint(style, value)
        when "z-index"
          style.z_index = (value.strip == "auto" ? nil : value.to_i?)
        when "transition"
          style.transitions = parse_transition(value)
        when "animation"
          style.animation = parse_animation(value)
        when "padding"
          style.padding = parse_padding(value)
        when "padding-left"
          style.padding.left = cells(value)
        when "padding-top"
          style.padding.top = cells(value)
        when "padding-right"
          style.padding.right = cells(value)
        when "padding-bottom"
          style.padding.bottom = cells(value)
        when "margin"
          style.margin = parse_margin(value)
        when "margin-left"
          style.margin.left = cells(value)
        when "margin-top"
          style.margin.top = cells(value)
        when "margin-right"
          style.margin.right = cells(value)
        when "margin-bottom"
          style.margin.bottom = cells(value)
        else
          # Unknown / not-yet-supported property: ignore.
        end
      end

      # Whether *property* is a property this module (or the geometry module)
      # knows how to apply — used for malformed-CSS diagnostics.
      def self.known?(property : String) : Bool
        KNOWN.includes?(property) || property.starts_with?("border") || Geometry.handles?(property)
      end

      KNOWN = Set{
        "color", "background-color", "background", "font", "font-weight",
        "font-style", "text-decoration", "visibility", "display", "opacity",
        "tab-size", "box-shadow", "tint", "z-index", "transition", "animation",
        "padding", "padding-left", "padding-top", "padding-right", "padding-bottom",
        "margin", "margin-left", "margin-top", "margin-right", "margin-bottom",
        "alternate-background-color", "gridline-color",
        "selection-color", "selection-background-color",
      }

      # Extracts a color from a `background` shorthand: the first token that
      # resolves to a real color (functions/keywords, or a named/hex color whose
      # `Colors.convert` isn't the `-1` "unknown" sentinel).
      private def self.parse_background_color(value : String, current_fg : Int32?) : Int32?
        value.split.each do |token|
          case resolved = ColorValue.resolve(token, current_fg)
          when Int32 then return resolved
          when String
            color = Colors.convert(token).to_i32
            return color unless color == -1
          end
        end
        nil
      end

      # Parses a `tint`: a color the widget is overlaid toward, plus an optional
      # strength (`0..1`). `tint: #ff0000 0.3` ⇒ 30% red overlay; `tint: none`
      # clears it. The color may be any form `color`/`background-color` accept; a
      # bare `0..1` number anywhere in the value is taken as the strength.
      private def self.parse_tint(style : Style, value : String) : Nil
        if value.strip == "none"
          style.tint = nil
          return
        end
        color : Int32? = nil
        alpha : Float64? = nil
        value.split.each do |token|
          if !token.starts_with?('#') && (f = token.to_f?) && 0.0 <= f <= 1.0
            alpha = f
          else
            case resolved = ColorValue.resolve(token, style.fg)
            when Int32 then color = resolved unless resolved == -1
            when String
              c = Colors.convert(token).to_i32
              color = c unless c == -1
            end
          end
        end
        color.try do |c|
          style.tint = c
          alpha.try { |a| style.tint_alpha = a }
        end
      end

      # Parses a `transition`: comma-separated `<property> <duration> [easing]`
      # entries, e.g. `opacity 0.3s ease-in-out, background-color 200ms`. Yields a
      # map of property name -> `{duration, easing}`; `none` clears it. Unknown
      # easings fall back to a gentle in/out sine.
      private def self.parse_transition(value : String) : Hash(String, Tuple(Time::Span, Animation::Easing))?
        return nil if value.strip == "none" || value.strip.empty?
        out = {} of String => Tuple(Time::Span, Animation::Easing)
        value.split(',').each do |entry|
          toks = entry.split
          next if toks.empty?
          dur = (toks[1]?.try { |t| parse_time(t) }) || 0.3.seconds
          easing = toks[2]?.try { |e| css_easing(e) } || Animation::Easing::InOutSine
          out[toks[0]] = {dur, easing}
        end
        out.empty? ? nil : out
      end

      # Parses `animation: <name> <duration> [easing] [<count>|infinite] [alternate]`,
      # e.g. `pulse 2s ease-in-out infinite alternate`. Order after name/duration
      # is flexible. `none`/empty clears it.
      private def self.parse_animation(value : String) : Style::AnimationSpec?
        toks = value.split
        return nil if toks.empty? || toks[0] == "none"
        name = toks[0]
        dur = 1.seconds
        easing = Animation::Easing::Linear
        iterations : Int32? = 1
        alternate = false
        toks[1..].each do |t|
          # A unit-suffixed token is the duration; a bare integer is the
          # iteration count (so `... 0.15s ... 1` doesn't read "1" as seconds).
          if (t.ends_with?("ms") || t.ends_with?("s")) && (span = parse_time(t))
            dur = span
          elsif t == "infinite"
            iterations = nil
          elsif t == "alternate"
            alternate = true
          elsif (n = t.to_i?)
            iterations = n
          else
            easing = css_easing(t)
          end
        end
        Style::AnimationSpec.new(name, dur, easing, iterations, alternate)
      end

      # `0.3s` / `200ms` / bare seconds -> `Time::Span`.
      private def self.parse_time(s : String) : Time::Span?
        if s.ends_with? "ms"
          s[0...-2].to_f?.try &.milliseconds
        elsif s.ends_with? "s"
          s[0...-1].to_f?.try &.seconds
        else
          s.to_f?.try &.seconds
        end
      end

      # Maps a CSS timing-function keyword to an `Animation::Easing`.
      private def self.css_easing(name : String) : Animation::Easing
        case name
        when "linear"              then Animation::Easing::Linear
        when "ease-in"             then Animation::Easing::InQuad
        when "ease-out"            then Animation::Easing::OutQuad
        when "ease", "ease-in-out" then Animation::Easing::InOutSine
        else                            Animation::Easing::InOutSine
        end
      end

      # Applies any `border*` property. Border color is a single whole-border
      # value in crysterm's model, so per-side `*-color` longhands all set it;
      # per-side widths/styles are honored individually.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      private def self.apply_border(style : Style, property : String, value : String) : Nil
        border = style.border
        case property
        when "border"
          style.border = parse_border(value)
        when "border-width"
          w = border_cells(value)
          border.left = border.top = border.right = border.bottom = w
        when "border-color"
          border.fg = ColorValue.resolve(value, border.fg)
        when "border-top-color"
          border.fg_top = border_side_color(value, border)
        when "border-right-color"
          border.fg_right = border_side_color(value, border)
        when "border-bottom-color"
          border.fg_bottom = border_side_color(value, border)
        when "border-left-color"
          border.fg_left = border_side_color(value, border)
        when "border-style"
          apply_border_style border, value, {:left, :top, :right, :bottom}
        when "border-top"          then apply_border_side border, :top, value
        when "border-right"        then apply_border_side border, :right, value
        when "border-bottom"       then apply_border_side border, :bottom, value
        when "border-left"         then apply_border_side border, :left, value
        when "border-top-width"    then border.top = border_cells(value)
        when "border-right-width"  then border.right = border_cells(value)
        when "border-bottom-width" then border.bottom = border_cells(value)
        when "border-left-width"   then border.left = border_cells(value)
        when "border-top-style"    then apply_border_style border, value, {:top}
        when "border-right-style"  then apply_border_style border, value, {:right}
        when "border-bottom-style" then apply_border_style border, value, {:bottom}
        when "border-left-style"   then apply_border_style border, value, {:left}
        else
          # Unknown border-* property: ignore.
        end
      end

      # Resolves a per-side border color value to a native `0xRRGGBB` int
      # (`border-*-color` stores ints, not the string form `border-color` keeps).
      private def self.border_side_color(value : String, border : Border) : Int32?
        case resolved = ColorValue.resolve(value, border.fg)
        when Int32  then resolved
        when String then Colors.convert(resolved).to_i32
        else             nil
        end
      end

      # A border-shorthand token that is a width: a bare integer, optionally
      # with the default `px` unit (e.g. `2`, `2px`). Anything else in a
      # shorthand is a style keyword or a color.
      WIDTH_TOKEN = /\A\d+(?:px)?\z/

      # Maps a CSS `border-style` keyword to a `BorderType`, or `nil` if the
      # token isn't a style keyword (a width, color, or `none`). `solid`/`line`
      # both mean the light line border; `bg`/`background` the fill-char border;
      # `dashed`/`dotted`/`double` their respective glyph sets.
      private def self.border_type_keyword(token : String) : BorderType?
        case token
        when "solid", "line"    then BorderType::Line
        when "dashed"           then BorderType::Dashed
        when "dotted"           then BorderType::Dotted
        when "double"           then BorderType::Double
        when "bg", "background" then BorderType::Bg
        else                         nil
        end
      end

      # A single-side `border-<side>` shorthand: a width sets that side, a style
      # keyword sets the border type (or hides the side with `none`), and any
      # other token is treated as the whole-border color.
      private def self.apply_border_side(border : Border, side : Symbol, value : String) : Nil
        value.split.each do |token|
          if token == "none"
            set_side border, side, 0
          elsif type = border_type_keyword(token)
            border.type = type
            ensure_side border, side
          elsif token.matches?(WIDTH_TOKEN)
            set_side border, side, border_cells(token)
          else
            border.fg = ColorValue.resolve(token, border.fg)
          end
        end
      end

      # Applies a `border-style` keyword to the given *sides*: `none` hides them,
      # any line/fill keyword (`solid`/`line`/`dashed`/`dotted`/`double`/`bg`)
      # sets the type and enables the sides.
      private def self.apply_border_style(border : Border, value : String, sides : Tuple) : Nil
        if value == "none"
          sides.each { |side| set_side border, side, 0 }
        elsif type = border_type_keyword(value)
          border.type = type
          sides.each { |side| ensure_side border, side }
        end
      end

      private def self.set_side(border : Border, side : Symbol, width : Int32) : Nil
        case side
        when :left   then border.left = width
        when :top    then border.top = width
        when :right  then border.right = width
        when :bottom then border.bottom = width
        end
      end

      # Ensures a side has at least width 1 (so a `solid` style makes it visible).
      private def self.ensure_side(border : Border, side : Symbol) : Nil
        current = case side
                  when :left  then border.left
                  when :top   then border.top
                  when :right then border.right
                  else             border.bottom
                  end
        set_side border, side, 1 if current == 0
      end

      # Resolves a two-valued keyword property (e.g. `font-weight: bold|normal`)
      # to a Bool, leaving the current value untouched for unrecognized inputs.
      private def self.bool_keyword(value, *, on, off, current) : Bool
        case value
        when on  then true
        when off then false
        else          current
        end
      end

      # Parses a length to terminal cells, honoring CSS units through the shared
      # `Length` divisor table (`"2"` -> 2, `"200px"` -> 20 with the default `px`
      # divisor, `"1em"` -> 1). Inputs that aren't a cell count — percentages
      # (`50%`), ranges (`5-10`), an unmapped unit (`3cm`), junk — have no meaning
      # in the cell model and yield `0` rather than a silently-wrong number.
      private def self.cells(value : String) : Int32
        Length.to_cells(value) || 0
      end

      # Like `cells`, but a *positive* sub-cell width — e.g. a `2px` border with
      # the default `px` divisor, which rounds to 0 — clamps up to 1 so a declared
      # border doesn't silently vanish. An explicit `0`, a negative width, or a
      # non-length value (`50%`, junk, a dropped unit) still yields 0.
      #
      # A border width is almost always a bare number or one unit'd length, so
      # resolve the fractional cells in a single pass (`to_cells_f`) and clamp from
      # it. Only a `calc()` border (rare) falls back to `to_cells`.
      private def self.border_cells(value : String) : Int32
        if frac = Length.to_cells_f(value)
          cells = Length.to_cell_count(frac)
          return cells unless cells == 0
          return frac > 0 ? 1 : 0 # positive sub-cell width → keep it visible
        end
        c = Length.to_cells(value) # a `calc()` border still resolves here
        (c && c > 0) ? c : 0
      end

      # Parses a `box-shadow`. `none` disables the shadow; otherwise a default
      # drop shadow is enabled, and a bare `0..1` number anywhere in the value is
      # taken as its alpha (opacity). The full CSS offset/blur/spread/color
      # syntax is accepted but only its presence (and optional alpha) is honored.
      private def self.parse_box_shadow(value : String) : Shadow
        return Shadow.from(false) if value.strip == "none"
        alpha = value.split.compact_map(&.to_f?).find { |num| 0.0 <= num <= 1.0 }
        alpha ? Shadow.from(alpha) : Shadow.from(true)
      end

      # Parses the CSS `padding` shorthand (1-4 cell values, CSS TRBL order)
      # into a `Padding`.
      private def self.parse_padding(value : String) : Padding
        v = value.split.map { |part| cells(part) }
        case v.size
        when 1 then Padding.new(v[0], v[0], v[0], v[0])
        when 2 then Padding.new(v[1], v[0], v[1], v[0]) # L,T,R,B from V,H
        when 3 then Padding.new(v[1], v[0], v[1], v[2]) # from T,H,B
        when 4 then Padding.new(v[3], v[0], v[1], v[2]) # from T,R,B,L
        else        Padding.default
        end
      end

      # Parses the CSS `margin` shorthand (1-4 cell values, CSS TRBL order)
      # into a `Margin`. Same grammar as `padding`.
      private def self.parse_margin(value : String) : Margin
        v = value.split.map { |part| cells(part) }
        case v.size
        when 1 then Margin.new(v[0], v[0], v[0], v[0])
        when 2 then Margin.new(v[1], v[0], v[1], v[0]) # L,T,R,B from V,H
        when 3 then Margin.new(v[1], v[0], v[1], v[2]) # from T,H,B
        when 4 then Margin.new(v[3], v[0], v[1], v[2]) # from T,R,B,L
        else        Margin.default
        end
      end

      # Parses a `border` shorthand. Recognizes a width (cells), a style keyword
      # (`solid`/`line` -> line border, `bg` -> background border, `none` -> no
      # border), and otherwise treats a token as a color.
      private def self.parse_border(value : String) : Border
        return Border.new(0) if value.strip == "none"
        border = Border.new # default: line border, 1 cell on each side
        value.split.each do |token|
          if type = border_type_keyword(token)
            border.type = type
          elsif token.matches?(WIDTH_TOKEN)
            w = border_cells(token)
            border.left = border.top = border.right = border.bottom = w
          else
            border.fg = token
          end
        end
        border
      end
    end
  end
end
