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
        # CSS property names are case-insensitive, so match on a lower-cased
        # name (`COLOR` == `color`). Custom properties (`--Foo`) are *case-
        # sensitive* and aren't handled by this `case` anyway, so they're left
        # untouched.
        prop = Case.fold_property(property)
        return apply_border(style, prop, value) if prop.starts_with?("border")

        case prop
        when "color"
          with_color(value, style.fg) { |c| style.fg = c }
        when "background-color"
          with_color(value, style.fg) { |c| style.bg = c }
        when "alternate-background-color"
          # Background of every other row in a `Table`/`ListTable` with
          # `alternate_rows` on (Qt's `alternate-background-color`). Lives in the
          # `alternate_row` sub-style.
          with_color(value, style.fg) { |c| style.alternate_background = c }
        when "gridline-color"
          # Color of a table's internal gridlines (Qt's `gridline-color`).
          with_color(value, style.fg) { |c| style.gridline_color = c }
        when "selection-color", "selection-background-color"
          # Selected-item colors. These target a *different* `Style` (the
          # `:selected` state), so they can't be applied to *this* style here —
          # the cascade rewrites them onto the selected state (see
          # `Cascade#selection_entries`). Named here only so they're not treated
          # as unknown; the value is consumed there.
        when "background"
          # `background` shorthand: pull out the color *and* a `url(...)` image.
          # Per CSS shorthand semantics this resets the image layer, so a
          # `background` with no `url(...)` clears any prior `background-image`.
          # (position/repeat and the `/size` syntax are not parsed from the
          # shorthand yet; set `background-size` longhand for scaling.)
          parse_background_color(value, style.fg).try { |color| style.bg = color }
          style.background_image = parse_background_image(value)
        when "background-image"
          # `none` (or any value without a `url(...)`) clears it.
          style.background_image = parse_background_image(value)
        when "background-size"
          style.background_size = parse_background_size(value)
        when "font"
          # `font` shorthand: only the weight/style words mean anything here;
          # presence sets the attribute, absence resets it (shorthand semantics).
          # The weight is recognized exactly as the `font-weight` longhand does
          # (via `font_weight_bold`), so the numeric/relative CSS weights count —
          # `font: 700 14px serif` / `font: bolder …` are bold, not only the
          # literal `bold` keyword (otherwise a clearly-bold shorthand silently
          # rendered non-bold, the mirror of the longhand bug already fixed).
          # `oblique` slants like `italic`.
          words = Case.fold_keyword(value).split
          style.bold = words.any? { |w| font_weight_bold(w, false) }
          style.italic = words.includes?("italic") || words.includes?("oblique")
        when "font-weight"
          style.bold = font_weight_bold(value, style.bold?)
        when "font-style"
          # `italic` and `oblique` both map to the terminal's single slant
          # attribute; `normal` clears it. The `font` shorthand already treats
          # `oblique` as italic (see above), so the longhand must agree —
          # otherwise `font-style: oblique` silently rendered upright, the mirror
          # of the `font-weight` longhand/shorthand fix. An unrecognized value
          # leaves the current slant unchanged.
          style.italic = font_style_italic(value, style.italic?)
        when "text-decoration"
          words = Case.fold_keyword(value).split
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
          # Only the recognized keywords act; any *other* value — a typo, or a
          # `var(--x)` whose custom property is undefined and so collapsed to the
          # empty string — is *ignored*, per CSS's "drop the invalid declaration"
          # rule, leaving any previously-cascaded visibility intact. The old
          # `!= "hidden"` form forced `visible = true` for such a value, silently
          # *un-hiding* a widget a lower-priority rule had hidden (the mirror of
          # the `z-index` invalid-value bug). `collapse` hides like `hidden`.
          case Case.fold_keyword(value.strip)
          when "visible"            then style.visible = true
          when "hidden", "collapse" then style.visible = false
          end
        when "display"
          # As with `visibility`: `none` hides, any other *non-empty* value shows.
          # An empty/blank value (e.g. an undefined `var()` collapsed to "") is
          # ignored rather than forcing `visible = true` — which would otherwise
          # un-hide a widget a lower-priority `display: none` had hidden.
          v = Case.fold_keyword(value.strip)
          style.visible = (v != "none") unless v.empty?
        when "opacity"
          # CSS clamps opacity into `[0, 1]`; an out-of-range value would
          # otherwise flow straight into `Colors.blend` as a bad mix factor.
          value.to_f?.try { |num| style.alpha = num.clamp(0.0, 1.0) }
        when "tab-size"
          style.tab_size = cells(value)
        when "box-shadow"
          style.shadow = parse_box_shadow(value)
        when "tint"
          parse_tint(style, value)
        when "z-index"
          # `auto` clears it (back to the base layer). An *unparseable* value —
          # e.g. an `auto`-typo, or a `var(--x)` whose custom property is
          # undefined and so collapsed to the empty string — is *ignored*, per
          # CSS's "drop the invalid declaration" rule, leaving any
          # previously-cascaded z-index intact. The old `value.to_i?` form
          # assigned the `nil` straight through, so such a value silently
          # *cleared* a z-index a lower-priority rule had set (e.g. the theme's
          # `Menu { z-index: 10 }` overlay promotion), un-compositing the
          # overlay. This now mirrors `opacity` above, which already guards its
          # parse with `.try`.
          if Case.fold_keyword(value.strip) == "auto"
            style.z_index = nil
          else
            value.to_i?.try { |z| style.z_index = z }
          end
        when "transition"
          style.transitions = parse_transition(value)
        when "animation"
          style.animation = parse_animation(value)
        when "padding"
          style.padding = parse_padding(value)
        when "padding-left"
          style.padding.left = cells(value)
        when "padding-top"
          style.padding.top = cells(value, vertical: true)
        when "padding-right"
          style.padding.right = cells(value)
        when "padding-bottom"
          style.padding.bottom = cells(value, vertical: true)
        when "margin"
          style.margin = parse_margin(value)
        when "margin-left"
          style.margin.left = cells(value)
        when "margin-top"
          style.margin.top = cells(value, vertical: true)
        when "margin-right"
          style.margin.right = cells(value)
        when "margin-bottom"
          style.margin.bottom = cells(value, vertical: true)
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
        "color", "background-color", "background", "background-image",
        "background-size", "font", "font-weight",
        "font-style", "text-decoration", "visibility", "display", "opacity",
        "tab-size", "box-shadow", "tint", "z-index", "transition", "animation",
        "padding", "padding-left", "padding-top", "padding-right", "padding-bottom",
        "margin", "margin-left", "margin-top", "margin-right", "margin-bottom",
        "alternate-background-color", "gridline-color",
        "selection-color", "selection-background-color",
      }

      # Splits a multi-token shorthand value on top-level whitespace, but keeps a
      # function's parenthesized argument list intact — so a color function with
      # internal spaces/commas (`rgb(30, 30, 46)`, `hsl(210, 50%, 40%)`) survives
      # as a single token instead of being shredded by a plain `String#split`. A
      # plain `split` would break the color out of a `background`/`tint` shorthand
      # (`background: rgb(30, 30, 46) url(x.png)` parsing to *no* background),
      # while the `background-color` longhand — which resolves the whole value at
      # once — handled it fine. Whitespace inside `(...)` stays within the token;
      # a `url(...)` (no inner spaces) tokenizes exactly as before.
      private def self.split_top_level(value : String) : Array(String)
        tokens = [] of String
        depth = 0
        start = 0
        value.each_char_with_index do |ch, i|
          case ch
          when '(' then depth += 1
          when ')' then depth -= 1 if depth > 0
          else
            if depth == 0 && ch.whitespace?
              tokens << value[start...i] unless i == start
              start = i + 1
            end
          end
        end
        tokens << value[start..] if start < value.size
        tokens
      end

      # Extracts a color from a `background`/`background-color` value. A gradient
      # (`qlineargradient(...)` etc.) is collapsed to a representative solid color;
      # otherwise the first token that resolves to a real color wins (functions/
      # keywords, or a named/hex color whose `Colors.convert` isn't the `-1`
      # "unknown" sentinel).
      private def self.parse_background_color(value : String, current_fg : Int32?) : Int32?
        # A gradient spans multiple whitespace-split tokens, so collapse it whole
        # (to its averaged solid) before the per-token scan below.
        if grad = ColorValue.gradient_color(value)
          return grad
        end
        split_top_level(value).each do |token|
          case resolved = ColorValue.resolve(token, current_fg)
          when Int32 then return resolved
          when String
            color = Colors.convert_cached(token)
            return color unless color == -1
          end
        end
        nil
      end

      # Matches a CSS `url(...)` token, capturing the (optionally quoted) path.
      URL_TOKEN = /url\(\s*['"]?([^'")]+?)['"]?\s*\)/

      # Extracts the first `url(...)` path from a `background`/`background-image`
      # value, e.g. `url("pics/bg.png")` ⇒ `pics/bg.png`. Returns `nil` when there
      # is no `url(...)` (e.g. `none`, or a `background` shorthand carrying only a
      # color) — which, assigned to `background_image`, clears any prior image.
      private def self.parse_background_image(value : String) : String?
        URL_TOKEN.match(value).try &.[1]
      end

      # Maps a `background-size` value to a `Style::BackgroundSize`. `cover`
      # (preserve aspect, fill, crop) is both the keyword and the fallback for
      # unrecognized input; `100% 100%` is the CSS spelling of a full stretch.
      private def self.parse_background_size(value : String) : Style::BackgroundSize
        case value.strip.downcase
        when "contain"           then Style::BackgroundSize::Contain
        when "auto"              then Style::BackgroundSize::Auto
        when "100% 100%", "100%" then Style::BackgroundSize::Stretch
        else                          Style::BackgroundSize::Cover
        end
      end

      # Parses a `tint`: a color the widget is overlaid toward, plus an optional
      # strength (`0..1`). `tint: #ff0000 0.3` ⇒ 30% red overlay; `tint: none`
      # clears it. The color may be any form `color`/`background-color` accept; a
      # bare `0..1` number anywhere in the value is taken as the strength.
      private def self.parse_tint(style : Style, value : String) : Nil
        if Case.fold_keyword(value.strip) == "none"
          style.tint = nil
          return
        end
        color : Int32? = nil
        alpha : Float64? = nil
        split_top_level(value).each do |token|
          if !token.starts_with?('#') && (f = token.to_f?) && 0.0 <= f <= 1.0
            alpha = f
          else
            case resolved = ColorValue.resolve(token, style.fg)
            when Int32 then color = resolved unless resolved == -1
            when String
              c = Colors.convert_cached(token)
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
        return nil if Case.fold_keyword(value.strip) == "none" || value.strip.empty?
        out = {} of String => Tuple(Time::Span, Animation::Easing)
        value.split(',').each do |entry|
          toks = entry.split
          next if toks.empty?
          dur = (toks[1]?.try { |t| parse_time(t) }) || 0.3.seconds
          easing = toks[2]?.try { |e| css_easing(e) } || Animation::Easing::InOutSine
          # The animated property name is a CSS property — case-insensitive — so
          # fold it (`Background-Color` == `background-color`). The consumer
          # (`Widget#apply_style_transitions`) matches it against lower-cased
          # literals (`"background-color"`, `"opacity"`, …), so an unfolded
          # capitalized name would silently never tween.
          out[Case.fold_property(toks[0])] = {dur, easing}
        end
        out.empty? ? nil : out
      end

      # Parses `animation: <name> <duration> [easing] [<count>|infinite] [alternate]`,
      # e.g. `pulse 2s ease-in-out infinite alternate`. Order after name/duration
      # is flexible. `none`/empty clears it.
      private def self.parse_animation(value : String) : Style::AnimationSpec?
        toks = value.split
        return nil if toks.empty? || Case.fold_keyword(toks[0]) == "none"
        name = toks[0]
        dur = 1.seconds
        easing = Animation::Easing::Linear
        iterations : Int32? = 1
        alternate = false
        toks[1..].each do |t|
          # A unit-suffixed token is the duration; a bare integer is the
          # iteration count (so `... 0.15s ... 1` doesn't read "1" as seconds).
          tl = Case.fold_unit(t)
          if (tl.ends_with?("ms") || tl.ends_with?("s")) && (span = parse_time(t))
            dur = span
          elsif tl == "infinite"
            iterations = nil
          elsif tl == "alternate"
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
        s = Case.fold_unit(s.strip) # time units (`s`/`ms`) are case-insensitive
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
        case Case.fold_keyword(name)
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
      private def self.apply_border(style : Style, property : String, value : String) : Nil
        border = style.border
        case property
        when "border"
          style.border = parse_border(value)
        when "border-width"
          # A cell is taller than wide, so the top/bottom edges (whose width is a
          # *vertical* measurement) scale by the cell aspect ratio just like the
          # `border-top-width`/`border-bottom-width` longhands and the `border`
          # shorthand do — otherwise `border-width: 200px` gave a 20-cell top edge
          # where `border-top-width: 200px` (correctly) gives 10.
          border.left = border.right = border_cells(value)
          border.top = border.bottom = border_cells(value, vertical: true)
        when "border-color"
          with_color(value, border.fg) { |c| border.fg = c }
        when "border-top-color"
          with_color(value, border.fg) { |c| border.fg_top = coerce_color_int(c) }
        when "border-right-color"
          with_color(value, border.fg) { |c| border.fg_right = coerce_color_int(c) }
        when "border-bottom-color"
          with_color(value, border.fg) { |c| border.fg_bottom = coerce_color_int(c) }
        when "border-left-color"
          with_color(value, border.fg) { |c| border.fg_left = coerce_color_int(c) }
        when "border-style"
          apply_border_style border, value, {:left, :top, :right, :bottom}
        when "border-top"          then apply_border_side border, :top, value
        when "border-right"        then apply_border_side border, :right, value
        when "border-bottom"       then apply_border_side border, :bottom, value
        when "border-left"         then apply_border_side border, :left, value
        when "border-top-width"    then border.top = border_cells(value, vertical: true)
        when "border-right-width"  then border.right = border_cells(value)
        when "border-bottom-width" then border.bottom = border_cells(value, vertical: true)
        when "border-left-width"   then border.left = border_cells(value)
        when "border-top-style"    then apply_border_style border, value, {:top}
        when "border-right-style"  then apply_border_style border, value, {:right}
        when "border-bottom-style" then apply_border_style border, value, {:bottom}
        when "border-left-style"   then apply_border_style border, value, {:left}
        else
          # Unknown border-* property: ignore.
        end
      end

      # Resolves *value* to a color and yields it to *block*, but *drops* a blank
      # value rather than letting it clobber the color. A `var(--x)` whose custom
      # property is undefined collapses to "" before reaching here (the cascade
      # resolves `var()` first); the old `style.fg = ColorValue.resolve("", ...)`
      # form then ran the empty string through `Colors.convert`, which maps an
      # unknown spec to the `-1` terminal-default sentinel — silently resetting a
      # color a lower-priority rule had set. CSS instead drops such an invalid
      # declaration, leaving the previously-cascaded color intact. This mirrors the
      # invalid-value guards already in place for `z-index`/`visibility`/`display`.
      # (`transparent` resolves to a genuine `-1` `Int32`, not a blank string, so
      # it is unaffected.)
      private def self.with_color(value : String, current : Int32?, & : (Int32 | String | Nil) ->) : Nil
        return if value.blank?
        yield ColorValue.resolve(value, current)
      end

      # Coerces a resolved color (`Int32`, a named/hex `String`, or `nil`) to the
      # native `0xRRGGBB` int the per-side `border-*-color` slots store (the
      # whole-border `border-color` keeps the string form via `Colorizable`).
      private def self.coerce_color_int(resolved : Int32 | String | Nil) : Int32?
        case resolved
        when Int32  then resolved
        when String then Colors.convert_cached(resolved)
        else             nil
        end
      end

      # Maps a CSS `border-style` keyword to a `BorderType`, or `nil` if the
      # token isn't a style keyword (a width, color, or `none`). `solid`/`line`
      # both mean the light line border; `bg`/`background` the fill-char border;
      # `dashed`/`dotted`/`double` their respective glyph sets.
      private def self.border_type_keyword(token : String) : BorderType?
        case Case.fold_keyword(token)
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
      # other token is the color for *that side* — routed to the per-side
      # `border-<side>-color` slot (`fg_top`/`fg_left`/…) the renderer reads, not
      # the whole-border `fg`. So `border-left: solid red` colors only the left
      # edge, matching CSS and the `border-<side>-color` longhand; the previous
      # whole-border assignment recolored every edge.
      private def self.apply_border_side(border : Border, side : Symbol, value : String) : Nil
        vertical = side == :top || side == :bottom
        # A width token (if any) is authoritative for the side; a bare style
        # keyword only *ensures* visibility when no width was given. A width is
        # honored at its rounded cell count (`0.04em`/`1px` → 0, `1.5em` → 2), so
        # a Qt-style sub-cell hairline collapses to no border instead of being
        # forced to a full-cell box by the accompanying `solid`. (Unlike the
        # explicit `border-width` *longhand*, a shorthand width is not clamped up.)
        explicit_width = nil
        type_seen = false
        value.split.each do |token|
          if Case.fold_keyword(token) == "none"
            explicit_width = 0
          elsif type = border_type_keyword(token)
            border.type = type
            type_seen = true
          elsif w = Length.to_cells(token, vertical)
            explicit_width = w
          else
            set_side_color border, side, ColorValue.resolve(token, border.fg)
          end
        end
        if explicit_width
          set_side border, side, explicit_width
        elsif type_seen
          ensure_side border, side
        end
      end

      # Sets the per-side border color (`fg_top`/`fg_right`/`fg_bottom`/`fg_left`)
      # for the `border-<side>` shorthand, coercing the resolved color to the
      # native int form those slots store — the same routing the
      # `border-<side>-color` longhand uses.
      private def self.set_side_color(border : Border, side : Symbol, resolved : Int32 | String | Nil) : Nil
        c = coerce_color_int(resolved)
        case side
        when :top    then border.fg_top = c
        when :right  then border.fg_right = c
        when :bottom then border.fg_bottom = c
        when :left   then border.fg_left = c
        end
      end

      # Applies a `border-style` keyword to the given *sides*: `none` hides them,
      # any line/fill keyword (`solid`/`line`/`dashed`/`dotted`/`double`/`bg`)
      # sets the type and enables the sides.
      private def self.apply_border_style(border : Border, value : String, sides : Tuple) : Nil
        if Case.fold_keyword(value.strip) == "none"
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

      # Resolves a CSS `font-weight` to the terminal's single bold attribute.
      # Beyond the `bold`/`normal` keywords this also honors the *numeric* CSS
      # weights (`font-weight: 700`) and the relative `bolder`/`lighter`, which a
      # plain keyword match silently dropped — so a theme's `font-weight: 600`
      # rendered as non-bold while a browser shows it bold. The numeric cutoff is
      # Qt's (`QFont#bold` is `weight > Medium(500)`), matching crysterm's Qt
      # conventions: a weight over 500 (`semibold`/`bold`/`bolder` and up) is
      # bold; `normal`/`lighter` and 100..500 are not. An unrecognized value
      # leaves the current weight unchanged.
      private def self.font_weight_bold(value : String, current : Bool) : Bool
        case v = Case.fold_keyword(value.strip)
        when "bold", "bolder"    then true
        when "normal", "lighter" then false
        else
          (w = v.to_i?) ? w > 500 : current
        end
      end

      # Resolves a CSS `font-style` value to the terminal's single slant
      # attribute. Both `italic` and `oblique` slant (the terminal has only one
      # slanted attribute), `normal` is upright, and an unrecognized value leaves
      # the current slant unchanged. CSS keyword values are case-insensitive, so
      # compare on the lower-cased value.
      private def self.font_style_italic(value : String, current : Bool) : Bool
        case Case.fold_keyword(value.strip)
        when "italic", "oblique" then true
        when "normal"            then false
        else                          current
        end
      end

      # Parses a length to terminal cells, honoring CSS units through the shared
      # `Length` divisor table (`"2"` -> 2, `"200px"` -> 20 with the default `px`
      # divisor, `"1em"` -> 1). Inputs that aren't a cell count — percentages
      # (`50%`), ranges (`5-10`), an unmapped unit (`3cm`), junk — have no meaning
      # in the cell model and yield `0` rather than a silently-wrong number.
      private def self.cells(value : String, vertical : Bool = false) : Int32
        Length.to_cells(value, vertical) || 0
      end

      # Like `cells`, but a *positive* sub-cell width — e.g. a `2px` border with
      # the default `px` divisor, which rounds to 0 — clamps up to 1 so a declared
      # border doesn't silently vanish. An explicit `0`, a negative width, or a
      # non-length value (`50%`, junk, a dropped unit) still yields 0.
      #
      # A border width is almost always a bare number or one unit'd length, so
      # resolve the fractional cells in a single pass (`to_cells_f`) and clamp from
      # it. Only a `calc()` border (rare) falls back to `to_cells`.
      private def self.border_cells(value : String, vertical : Bool = false) : Int32
        if frac = Length.to_cells_f(value, vertical)
          cells = Length.to_cell_count(frac)
          return cells if cells > 0
          return frac > 0 ? 1 : 0 # positive sub-cell width → keep it visible; 0 / negative → none
        end
        c = Length.to_cells(value, vertical) # a `calc()` border still resolves here
        (c && c > 0) ? c : 0
      end

      # Parses a `box-shadow`. `none` disables the shadow; otherwise a default
      # drop shadow is enabled, and a bare *fractional* `0..1` number anywhere in
      # the value is taken as its alpha (opacity). The full CSS offset/blur/
      # spread/color syntax is accepted but only its presence (and optional
      # alpha) is honored.
      #
      # The alpha token must carry a decimal point: that is what tells an opacity
      # (`0.3`) apart from an integer length offset. Otherwise a perfectly normal
      # `box-shadow: 0 4px 8px <color>` would read its `0` offset as alpha `0` — a
      # fully transparent, *invisible* shadow.
      private def self.parse_box_shadow(value : String) : Shadow
        return Shadow.from(false) if Case.fold_keyword(value.strip) == "none"
        alpha = value.split.compact_map { |t| t.includes?('.') ? t.to_f? : nil }.find { |num| 0.0 <= num <= 1.0 }
        alpha ? Shadow.from(alpha) : Shadow.from(true)
      end

      # Resolves the shared CSS `padding`/`margin` 1-4 value shorthand (CSS TRBL
      # order) into `{left, top, right, bottom}` cell counts, or `nil` for an
      # empty/over-long value. Each shorthand value maps to a horizontal
      # (left/right) and a vertical (top/bottom) slot, which scale absolute units
      # differently — so both axes are resolved and the right one is picked per
      # side.
      private def self.parse_sides(value : String) : Tuple(Int32, Int32, Int32, Int32)?
        parts = value.split
        h = parts.map { |part| cells(part) }
        v = parts.map { |part| cells(part, vertical: true) }
        case parts.size #     left,  top,  right, bottom
        when 1 then {h[0], v[0], h[0], v[0]}
        when 2 then {h[1], v[0], h[1], v[0]} # from V,H
        when 3 then {h[1], v[0], h[1], v[2]} # from T,H,B
        when 4 then {h[3], v[0], h[1], v[2]} # from T,R,B,L
        else        nil
        end
      end

      # Parses the CSS `padding` shorthand (1-4 cell values, CSS TRBL order)
      # into a `Padding`.
      private def self.parse_padding(value : String) : Padding
        if sides = parse_sides(value)
          Padding.new(*sides)
        else
          Padding.default
        end
      end

      # Parses the CSS `margin` shorthand (1-4 cell values, CSS TRBL order)
      # into a `Margin`. Same grammar as `padding`.
      private def self.parse_margin(value : String) : Margin
        if sides = parse_sides(value)
          Margin.new(*sides)
        else
          Margin.default
        end
      end

      # Parses a `border` shorthand. Recognizes a width (cells), a style keyword
      # (`solid`/`line` -> line border, `bg` -> background border, `none` -> no
      # border), and otherwise treats a token as a color.
      private def self.parse_border(value : String) : Border
        return Border.new(0) if Case.fold_keyword(value.strip) == "none"
        border = Border.new # default: line border, 1 cell on each side
        value.split.each do |token|
          if type = border_type_keyword(token)
            border.type = type
          elsif w = Length.to_cells(token)
            # One width for all four sides, honored at its rounded cell count
            # rather than clamping a sub-cell hairline up to a full-cell box —
            # so a Qt theme's thin border (`0.04em`/`1px` → 0) collapses to none
            # in the cell grid. (top/bottom scale absolute units differently.)
            border.left = border.right = w
            border.top = border.bottom = (Length.to_cells(token, vertical: true) || w)
          else
            border.fg = token
          end
        end
        border
      end
    end
  end
end
