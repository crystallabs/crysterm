module Crysterm
  module CSS
    # Translates CSS declarations (real CSS property names) onto a `Style`.
    #
    # Property names that have a clean CSS analog use that analog (`color`,
    # `background-color`, `font-weight`, ...). Where there is no standard CSS
    # property, a pragmatic spelling is chosen — e.g. reverse-video maps to
    # `text-decoration: reverse`, chrome glyphs to the `glyph` family, and the
    # fill characters to `fill-char` & co.
    module Properties
      # Applies a single `property: value` declaration onto *style*. Unknown
      # properties are ignored, matching CSS's forgiving behavior.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      def self.apply(style : Style, property : String, value : String) : Nil
        # CSS property names are case-insensitive (`COLOR` == `color`); custom
        # properties (`--Foo`) are case-*sensitive* and stay untouched.
        prop = Case.fold_property(property)
        return apply_border(style, prop, value) if prop.starts_with?("border")

        case prop
        when "color"
          with_color(value, style.fg) { |c| style.fg = c }
        when "background-color"
          with_color(value, style.fg) { |c| style.bg = c }
        when "alternate-background-color"
          # Background of every other row in a `Table`/`ListTable` with
          # `alternate_rows` on (Qt's property).
          with_color(value, style.fg) { |c| style.alternate_background_color = c }
        when "gridline-color"
          # Color of a table's internal gridlines (Qt's `gridline-color`).
          with_color(value, style.fg) { |c| style.gridline_color = c }
        when "selection-color", "selection-background-color"
          # Selected-item colors. These target a *different* `Style` (the
          # `:selected` state), so the cascade rewrites them onto it; named here
          # only so they're not treated as unknown.
        when "background"
          # `background` shorthand: pulls out the color *and* a `url(...)` image.
          # Per CSS shorthand semantics, no `url(...)` clears any prior
          # `background-image`. (position/repeat and `/size` aren't parsed from
          # the shorthand; use the `background-size` longhand for scaling.)
          #
          # A blank value (collapsed undefined `var(--x)`) is dropped, not
          # treated as a reset, per CSS's "drop the invalid declaration" rule.
          unless value.blank?
            parse_background_color(value, style.fg).try { |color| style.bg = color }
            style.background_image = parse_background_image(value)
          end
        when "background-image"
          # `none` (or any value without `url(...)`) clears it; a blank value is
          # dropped, leaving a previously-cascaded image intact.
          style.background_image = parse_background_image(value) unless value.blank?
        when "background-size"
          # A blank value is dropped: `parse_background_size("")` would fall
          # through to its `Cover` default, clobbering a lower-priority rule and
          # marking it `specified?`.
          style.background_size = parse_background_size(value) unless value.blank?
        when "font"
          # `font` shorthand: only the weight/style words matter. Weight is
          # recognized exactly as the `font-weight` longhand, so numeric/relative
          # CSS weights count too (`font: 700 14px serif` / `bolder` are bold);
          # `oblique` slants like `italic`.
          #
          # A blank value is dropped, per CSS's "drop the invalid declaration"
          # rule: `"".split` would hard-reset bold/italic to false.
          unless value.blank?
            words = Case.fold_keyword(value).split
            style.bold = words.any? { |w| font_weight_bold(w, false) }
            style.italic = words.includes?("italic") || words.includes?("oblique")
          end
        when "font-weight"
          style.bold = font_weight_bold(value, style.bold?)
        when "font-style"
          # `italic`/`oblique` both map to the terminal's single slant attribute;
          # `normal` clears it. An unrecognized value leaves the slant unchanged.
          style.italic = font_style_italic(value, style.italic?)
        when "text-decoration"
          # A blank value is dropped, per CSS's "drop the invalid declaration"
          # rule: `"".split` would hard-reset underline/blink/strike/reverse.
          unless value.blank?
            words = Case.fold_keyword(value).split
            style.underline = words.includes?("underline")
            style.blink = words.includes?("blink")
            # `line-through` maps to the terminal's strikethrough (SGR 9).
            style.strike = words.includes?("line-through")
            # `reverse` (alias `inverse`) maps to reverse-video — the classic TUI
            # highlight look, with no standard CSS spelling.
            style.reverse = words.includes?("reverse") || words.includes?("inverse")
          end
        when "visibility"
          # Only recognized keywords act; any other value is ignored, per CSS's
          # "drop the invalid declaration" rule, leaving previously-cascaded
          # visibility intact. `collapse` hides like `hidden`.
          case Case.fold_keyword(value.strip)
          when "visible"            then style.visible = true
          when "hidden", "collapse" then style.visible = false
          end
        when "display"
          # As with `visibility`: `none` hides, any other non-empty value shows.
          # A blank value is ignored rather than forcing `visible = true`.
          v = Case.fold_keyword(value.strip)
          style.visible = (v != "none") unless v.empty?
        when "opacity"
          # CSS `opacity` is a `<number>` *or* a `<percentage>` (`opacity: 0.5`
          # == `opacity: 50%`, per CSS Color 4), clamped into `[0, 1]` since an
          # out-of-range value would reach `Colors.blend` as a bad mix factor.
          parse_opacity(value).try { |num| style.opacity = num.clamp(0.0, 1.0) }
        when "tab-size"
          # Only a value resolving to a cell count sets the tab width; an
          # unparseable one is dropped, leaving the previous width intact. A
          # negative count is dropped too — `tab_char * tab_size` in the render
          # path raises on it.
          Length.to_cells(value).try { |c| style.tab_size = c if c >= 0 }
        when "box-shadow"
          # A blank value is dropped rather than enabling a default drop shadow:
          # `parse_box_shadow("")` finds neither `none` nor an opacity and returns
          # `Shadow.from(true)`.
          style.shadow = parse_box_shadow(value) unless value.blank?
        when "tint"
          parse_tint(style, value)
        when "z-index"
          # `auto` clears it (back to the base layer). An unparseable value is
          # ignored rather than clearing a z-index a lower-priority rule set
          # (e.g. a theme's `Menu { z-index: 10 }` overlay promotion).
          if Case.fold_keyword(value.strip) == "auto"
            style.z_index = nil
          else
            value.to_i?.try { |z| style.z_index = z }
          end
        when "transition"
          style.transitions = parse_transition(value)
        when "animation"
          style.animation = parse_animation(value)
        when "glyph"
          # Chrome-glyph override for the site this style lands on. `none` stores
          # the `Glyphs::NONE_STR` sentinel (omit on run roles, registry default
          # on cell roles); an unparseable/blank value is dropped. The value may
          # be a multi-codepoint grapheme (`⚠️`), which is kept whole.
          parse_glyph(value).try { |s| style.glyph = s }
        when "glyph-ascii" # per-tier longhands
          parse_glyph(value).try { |s| style.glyph_ascii = s }
        when "glyph-unicode"
          parse_glyph(value).try { |s| style.glyph_unicode = s }
        when "glyph-extended"
          parse_glyph(value).try { |s| style.glyph_extended = s }
        when "glyph-open" # delimiter pair for composed indicator markers
          parse_glyph(value).try { |s| style.glyph_open = s }
        when "glyph-close"
          parse_glyph(value).try { |s| style.glyph_close = s }
        when "glyphs"
          # Sequence steps: the (optionally quoted) string's characters are the
          # frames of the site's sequence role — `Loading { glyphs: "◐◓◑◒" }`.
          # `none` clears back to the registry sequence; a blank value is dropped.
          v = value.strip
          unless v.blank?
            if Case.fold_keyword(v) == "none"
              style.glyphs = nil
            else
              s = v.strip('"').strip('\'')
              style.glyphs = s unless s.empty?
            end
          end
        when "shadow-char-horizontal"
          # CSS spellings for the half-block (thin) shadow glyphs — the `Shadow`
          # axis/diagonal groups and per-corner overrides. `none` clears a glyph
          # back to the plain full-cell alpha blend; a wide char is dropped (a
          # shadow cell is one column). These only pick the glyphs — `box-shadow`
          # still switches the shadow itself on.
          with_cell_char(value) { |c| style.shadow.horizontal_char = c }
        when "shadow-char-vertical"
          with_cell_char(value) { |c| style.shadow.vertical_char = c }
        when "shadow-char-diagonal"
          with_cell_char(value) { |c| style.shadow.diagonal_char = c }
        when "shadow-char-top-left"
          with_cell_char(value) { |c| style.shadow.top_left_char = c }
        when "shadow-char-top-right"
          with_cell_char(value) { |c| style.shadow.top_right_char = c }
        when "shadow-char-bottom-left"
          with_cell_char(value) { |c| style.shadow.bottom_left_char = c }
        when "shadow-char-bottom-right"
          with_cell_char(value) { |c| style.shadow.bottom_right_char = c }
        when "fill-char"
          # `none` has no meaning for a fill (a cell is always painted), so it's
          # dropped like any other invalid value.
          char_value(value).try { |c| style.fill_char = c }
        when "padding"
          # A blank value is dropped rather than resetting padding to default.
          style.padding = parse_padding(value) unless value.blank?
        when "padding-left"
          # An unparseable/blank value is dropped rather than hard-resetting the
          # side to 0. Applies to all eight per-side longhands. A negative
          # padding value is an invalid declaration per CSS and is dropped too
          # (unlike margin, where negatives are legitimate).
          Length.to_cells(value).try { |c| style.padding.left = c if c >= 0 }
        when "padding-top"
          Length.to_cells(value, vertical: true).try { |c| style.padding.top = c if c >= 0 }
        when "padding-right"
          Length.to_cells(value).try { |c| style.padding.right = c if c >= 0 }
        when "padding-bottom"
          Length.to_cells(value, vertical: true).try { |c| style.padding.bottom = c if c >= 0 }
        when "margin"
          # A blank value is dropped rather than resetting margin to default.
          style.margin = parse_margin(value) unless value.blank?
        when "margin-left"
          Length.to_cells(value).try { |c| style.margin.left = c }
        when "margin-top"
          Length.to_cells(value, vertical: true).try { |c| style.margin.top = c }
        when "margin-right"
          Length.to_cells(value).try { |c| style.margin.right = c }
        when "margin-bottom"
          Length.to_cells(value, vertical: true).try { |c| style.margin.bottom = c }
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
        "glyph", "glyph-ascii", "glyph-unicode", "glyph-extended",
        "glyph-open", "glyph-close", "glyphs",
        "fill-char",
        "shadow-char-horizontal", "shadow-char-vertical", "shadow-char-diagonal",
        "shadow-char-top-left", "shadow-char-top-right",
        "shadow-char-bottom-left", "shadow-char-bottom-right",
      }

      # Parses a CSS glyph/character value to a `Char`: a (optionally quoted)
      # literal uses its first character; a bare number is a Unicode code
      # point, decimal (`9662`) or hex (`0x25BE`) — Qt's
      # `lineedit-password-character` convention; `none` yields the
      # `Glyphs::NONE` sentinel. Returns `nil` (drop the declaration) for a
      # blank value or an out-of-range code point.
      def self.parse_char(value : String) : Char?
        # `parse_glyph` reduced to its first code point: same control flow, only
        # the sentinel (`Glyphs::NONE` vs `NONE_STR`) and the result type differ.
        case s = parse_glyph(value)
        when nil              then nil
        when Glyphs::NONE_STR then Glyphs::NONE
        else                       s[0]
        end
      end

      # `parse_char`'s widened sibling for the CSS `glyph` family: keeps the
      # *whole* grapheme instead of its first code point, so a multi-codepoint
      # value (`⚠️` = base + VS16, a flag, any combining sequence) survives into
      # `Style#glyph`. `none` yields the `Glyphs::NONE_STR` sentinel; a numeric
      # value is still a single code point (Qt convention); a blank value yields
      # `nil`. A *cell*-role consumer later reduces the result to a lone `Char`.
      def self.parse_glyph(value : String) : String?
        v = value.strip
        return nil if v.empty?
        return Glyphs::NONE_STR if Case.fold_keyword(v) == "none"
        # An *unquoted* number is a code point (quotes not yet stripped).
        if v[0].ascii_number?
          cp = v.to_i?(prefix: true)
          return cp ? (cp.chr.to_s rescue nil) : nil
        end
        v = v.strip('"').strip('\'')
        v.empty? ? nil : v
      end

      # `parse_char` for values where `none` has no meaning (fill characters):
      # the sentinel is dropped like any other invalid value.
      private def self.char_value(value : String) : Char?
        parse_char(value).try { |c| c unless c == Glyphs::NONE }
      end

      # Resolves a single-cell-char CSS value and yields the char to assign:
      # `none` yields `nil` (clear the glyph), a one-column char yields itself,
      # and an unparseable or wide value is dropped (no yield), per CSS's
      # invalid-declaration rule.
      private def self.with_cell_char(value : String, & : Char? ->) : Nil
        return unless c = parse_char(value)
        if c == Glyphs::NONE
          yield nil
        elsif Unicode.width(c) == 1
          yield c
        end
      end

      # Splits a multi-token shorthand value on top-level whitespace, keeping a
      # function's parenthesized argument list intact so a color function with
      # internal spaces/commas (`rgb(30, 30, 46)`) survives as one token rather
      # than being shredded by a plain `String#split`.
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
      # Case-insensitive: CSS function names are (`URL("x.png")` == `url(...)`),
      # and a non-match is treated as an explicit image *clear* by consumers.
      URL_TOKEN = /url\(\s*['"]?([^'")]+?)['"]?\s*\)/i

      # Extracts the first `url(...)` path from a `background`/`background-image`
      # value, e.g. `url("pics/bg.png")` ⇒ `pics/bg.png`. Returns `nil` when there
      # is no `url(...)` (e.g. `none`, or a color-only `background` shorthand),
      # which clears any prior image when assigned to `background_image`.
      private def self.parse_background_image(value : String) : String?
        URL_TOKEN.match(value).try &.[1]
      end

      # Maps a `background-size` value to a `Style::BackgroundSize`. `cover`
      # (preserve aspect, fill, crop) is both the keyword and the fallback for
      # unrecognized input; `100% 100%` is the CSS spelling of a full stretch.
      # CSS is whitespace-insensitive between component values, so the two `100%`
      # tokens are tokenized rather than matched byte-for-byte.
      private def self.parse_background_size(value : String) : Style::BackgroundSize
        v = value.strip.downcase
        case v
        when "contain" then Style::BackgroundSize::Contain
        when "auto"    then Style::BackgroundSize::Auto
        else
          toks = v.split
          if !toks.empty? && toks.size <= 2 && toks.all?("100%")
            Style::BackgroundSize::Stretch
          else
            Style::BackgroundSize::Cover
          end
        end
      end

      # Parses a CSS `opacity` value: a bare `<number>` (`0.5`) or a
      # `<percentage>` (`50%` → `0.5`), per CSS Color 4. Returns `nil` for a
      # blank/non-numeric value (e.g. a collapsed undefined `var()`), so the
      # caller drops the declaration rather than resetting the opacity. The caller
      # clamps the result into `[0, 1]`.
      #
      # Only *finite* numbers pass: `to_f?` accepts strtod's `nan`/`inf`
      # spellings, and `NaN.clamp(0.0, 1.0)` is still NaN — which would flow
      # into `Colors.mix` on the first blended cell and raise `OverflowError`
      # at `(… * 65536).to_i` (and tween NaN through a declared transition).
      # `parse_tint`'s range guard already rejects NaN; this is the equivalent.
      private def self.parse_opacity(value : String) : Float64?
        v = value.strip
        if v.ends_with?('%')
          v[0...-1].to_f?.try { |n| n / 100.0 if n.finite? }
        else
          v.to_f?.try { |n| n if n.finite? }
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
          elsif c = ColorValue.solid(token, style.fg)
            # A real color (last one wins); `transparent`/unknown collapse to the
            # `-1` sentinel and `solid` drops them, leaving `color` untouched.
            color = c
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
      private def self.parse_transition(value : String) : Hash(String, Tuple(Time::Span, Easing))?
        return nil if Case.fold_keyword(value.strip) == "none" || value.strip.empty?
        out = {} of String => Tuple(Time::Span, Easing)
        value.split(',').each do |entry|
          toks = entry.split
          next if toks.empty?
          # CSS only pins <time> values positionally (1st = duration, 2nd = delay);
          # the easing keyword may sit before or after the time. So classify tokens
          # by kind rather than by index: `opacity ease-out 0.3s` and `color
          # ease-in` are as valid as `opacity 0.3s ease-in-out`. A unitless number
          # is not a duration (`300` is not `300s`), so it is ignored here.
          dur : Time::Span? = nil
          easing : Easing? = nil
          toks[1..].each do |t|
            tl = Case.fold_unit(t)
            if dur.nil? && (tl.ends_with?("ms") || tl.ends_with?("s")) && (span = parse_time(t))
              dur = span
            elsif easing.nil? && easing?(t)
              easing = css_easing(t)
            end
          end
          # Per CSS a negative <duration> invalidates the declaration — drop
          # the entry rather than storing it. Stored, the tween's
          # `elapsed / dur` is negative, clamped to 0.0 forever: the property
          # is pinned to the FROM value by an immortal 30fps `FrameClock` that
          # never completes (sticking `Window#animating?` true). The animation
          # path already defends this input (`total = 0.001 if total <= 0`).
          next if (d = dur) && d < Time::Span.zero
          # The animated property name is a CSS property — case-insensitive — so
          # fold it (`Background-Color` == `background-color`). The consumer
          # (`Widget#apply_style_transitions`) matches it against lower-cased
          # literals (`"background-color"`, `"opacity"`, …), so an unfolded
          # capitalized name would silently never tween.
          out[Case.fold_property(toks[0])] = {dur || 0.3.seconds, easing || Easing::InOutSine}
        end
        out.empty? ? nil : out
      end

      # Parses `animation: <name> <duration> [easing] [<delay>] [<count>|infinite] [alternate]`,
      # e.g. `pulse 2s ease-in-out infinite alternate`. Order after name/duration
      # is flexible. `none`/empty clears it.
      private def self.parse_animation(value : String) : Style::AnimationSpec?
        toks = value.split
        return nil if toks.empty? || Case.fold_keyword(toks[0]) == "none"
        name : String? = nil
        dur = 1.seconds
        dur_seen = false
        easing = Easing::Linear
        iterations : Int32? = 1
        alternate = false
        toks.each do |t|
          # Classify by kind, not by position: the CSS `animation` shorthand orders
          # its fields freely, so the @keyframes name is not necessarily first
          # (`2s linear infinite spin` is as valid as `spin 2s linear infinite`).
          # A unit-suffixed token is a time; a bare integer is the iteration count
          # (so `... 0.15s ... 1` doesn't read "1" as seconds).
          tl = Case.fold_unit(t)
          if (tl.ends_with?("ms") || tl.ends_with?("s")) && (span = parse_time(t))
            # Per the CSS shorthand the *first* <time> is the duration and the
            # *second* is the delay. Crysterm has no animation-delay, so only the
            # first time token sets the duration; a following delay is consumed
            # here but ignored — without this it overwrote the duration, so e.g.
            # `slidein 3s ease-in 1s infinite` ran at the 1s delay instead of 3s.
            dur = span unless dur_seen
            dur_seen = true
          elsif tl == "infinite"
            iterations = nil
          elsif tl == "alternate"
            alternate = true
          elsif easing?(t)
            easing = css_easing(t)
          elsif (n = t.to_i?)
            # A negative iteration count is invalid; drop the whole declaration
            # (mirroring parse_transition's negative-duration drop). `0` is valid
            # (play zero times) and handled at the driver.
            return nil if n < 0
            iterations = n
          else
            # Anything that is not a time, keyword, easing or count is the
            # keyframes name. Prefer the last such token.
            name = t
          end
        end
        # No name → no keyframes to resolve; treat as no animation.
        name.try { |n| Style::AnimationSpec.new(n, dur, easing, iterations, alternate) }
      end

      # `0.3s` / `200ms` / bare seconds -> `Time::Span`.
      private def self.parse_time(s : String) : Time::Span?
        s = Case.fold_unit(s.strip) # time units (`s`/`ms`) are case-insensitive
        if s.ends_with? "ms"
          sane_time(s[0...-2]).try &.milliseconds
        elsif s.ends_with? "s"
          sane_time(s[0...-1]).try &.seconds
        else
          sane_time(s).try &.seconds
        end
      end

      # A duration number fit for a `Time::Span`: finite and within a sane
      # magnitude. `to_f?` accepts exponents and strtod's `nan`/`inf`
      # spellings, and `9e30.seconds` raises `OverflowError` mid-cascade
      # (unrescued between `Properties.apply` and `Cascade.apply_sheets`, so
      # one bad token in a hot-reloaded stylesheet would crash the app). 1e7
      # seconds is ~115 days — far beyond any real animation, comfortably
      # inside `Time::Span`.
      private def self.sane_time(s : String) : Float64?
        s.to_f?.try { |n| n if n.finite? && n.abs <= 1e7 }
      end

      # Whether a token is a recognized CSS timing-function keyword (rather than an
      # animation/keyframes name or property). Classifies the tokens of a
      # shorthand by kind, so a name is not mistaken for an easing (and
      # vice-versa).
      private def self.easing?(name : String) : Bool
        case Case.fold_keyword(name)
        when "linear", "ease", "ease-in", "ease-out", "ease-in-out" then true
        else                                                             false
        end
      end

      # Maps a CSS timing-function keyword to an `Easing`.
      private def self.css_easing(name : String) : Easing
        case Case.fold_keyword(name)
        when "linear"              then Easing::Linear
        when "ease-in"             then Easing::InQuad
        when "ease-out"            then Easing::OutQuad
        when "ease", "ease-in-out" then Easing::InOutSine
        else                            Easing::InOutSine
        end
      end

      # Applies any `border*` property. Per-side colors and widths are honored
      # individually (`border-top-color`/`border-left-width` & co.); the border
      # *type* is a single whole-border value. The `border-color` shorthand
      # recolors every side, so it also clears any per-side color override.
      #
      private def self.apply_border(style : Style, property : String, value : String) : Nil
        border = style.border
        # `currentColor` in a border color is the element's text color (`color`
        # / `Style#fg`), per CSS — not the border's own existing color. Threaded
        # as the basis into every border-color resolution below; unused for a
        # concrete value (hex/named/`rgb()`/…).
        el_color = style.fg
        case property
        when "border"
          style.border = parse_border(value, el_color)
        when "border-width"
          apply_border_width border, value
        when "border-color"
          apply_border_color border, value, el_color
        when "border-top-color"    then apply_side_color border, Side::Top, value, el_color
        when "border-right-color"  then apply_side_color border, Side::Right, value, el_color
        when "border-bottom-color" then apply_side_color border, Side::Bottom, value, el_color
        when "border-left-color"   then apply_side_color border, Side::Left, value, el_color
        when "border-style"
          apply_border_style border, value, {Side::Left, Side::Top, Side::Right, Side::Bottom}
        when "border-top"               then apply_border_side border, Side::Top, value, el_color
        when "border-right"             then apply_border_side border, Side::Right, value, el_color
        when "border-bottom"            then apply_border_side border, Side::Bottom, value, el_color
        when "border-left"              then apply_border_side border, Side::Left, value, el_color
        when "border-top-width"         then border_cells?(value, vertical: true).try { |c| border.top = c }
        when "border-right-width"       then border_cells?(value).try { |c| border.right = c }
        when "border-bottom-width"      then border_cells?(value, vertical: true).try { |c| border.bottom = c }
        when "border-left-width"        then border_cells?(value).try { |c| border.left = c }
        when "border-top-style"         then apply_border_style border, value, {Side::Top}
        when "border-right-style"       then apply_border_style border, value, {Side::Right}
        when "border-bottom-style"      then apply_border_style border, value, {Side::Bottom}
        when "border-left-style"        then apply_border_style border, value, {Side::Left}
        when "border-radius"            then apply_border_radius border, value
        when "border-chars"             then apply_border_chars border, value
        when "border-top-left-char"     then apply_border_char border, Border::CharPosition::TopLeft, value
        when "border-top-right-char"    then apply_border_char border, Border::CharPosition::TopRight, value
        when "border-bottom-left-char"  then apply_border_char border, Border::CharPosition::BottomLeft, value
        when "border-bottom-right-char" then apply_border_char border, Border::CharPosition::BottomRight, value
        when "border-horizontal-char"   then apply_border_char border, Border::CharPosition::Horizontal, value
        when "border-vertical-char"     then apply_border_char border, Border::CharPosition::Vertical, value
        when "border-corner-char"       then apply_border_char border, Border::CharPosition::Corner, value
        else
          # Unknown border-* property: ignore.
        end
      end

      # The CSS `border-radius` shorthand, mapped honestly onto the cell grid:
      # a terminal can't render partial curves, so any positive radius turns a
      # light `Solid` border's corners into the arc family
      # (`BorderType::Rounded`, `╭╮╰╯`), and an explicit zero turns a
      # `Rounded` border back to square corners. Other families (`Double`/
      # `Dashed`/`Dotted`/`Fill`) are left alone — the author picked a stronger
      # corner statement than "slightly rounded". Qt themes' ubiquitous
      # `border-radius: 4px` thus rounds frames for free. Order note: the
      # `border` shorthand *replaces* the whole `Border`, so declare the
      # radius after it (as Qt themes conventionally do); an unparseable or
      # blank value is dropped.
      private def self.apply_border_radius(border : Border, value : String) : Nil
        v = value.strip
        return if v.empty?
        # First numeric component of the (possibly multi-value, unit-suffixed)
        # shorthand: `4px`, `0.5em 1em`, `50%` — any positive number rounds.
        return unless m = v.match(/-?\d+(?:\.\d+)?/)
        return unless r = m[0].to_f?
        if r > 0
          border.type = BorderType::Rounded if border.type.solid?
        else
          border.type = BorderType::Solid if border.type.rounded?
        end
      end

      # A `border-<position>-char` longhand: sets one border char override.
      # `none` clears the override back to the type's normal
      # glyph source (registry family / `fill_char`); an unparseable value —
      # or one that isn't exactly one column (a border cell must be) — is
      # dropped, per CSS's invalid-declaration rule.
      private def self.apply_border_char(border : Border, position : Border::CharPosition, value : String) : Nil
        with_cell_char(value) { |c| border.set_char position, c }
      end

      # The `border-chars` shorthand: six chars in
      # `tl tr bl br h v` order (`border-chars: "╭" "╮" "╰" "╯" "─" "│"`),
      # three for the `corner h v` groups, or one for everything. Each token
      # follows `apply_border_char`'s rules (`none` clears a position); a
      # declaration with an unparseable/wide token or another count is
      # dropped whole.
      private def self.apply_border_chars(border : Border, value : String) : Nil
        return if value.blank?
        tokens = split_top_level(value)
        chars = tokens.map { |token| parse_char(token) }
        return if chars.any?(Nil)
        resolved = chars.map { |c| c == Glyphs::NONE ? nil : c }
        return if resolved.any? { |c| c && Unicode.width(c) != 1 }
        case resolved.size
        when 6
          border.set_char Border::CharPosition::TopLeft, resolved[0]
          border.set_char Border::CharPosition::TopRight, resolved[1]
          border.set_char Border::CharPosition::BottomLeft, resolved[2]
          border.set_char Border::CharPosition::BottomRight, resolved[3]
          border.set_char Border::CharPosition::Horizontal, resolved[4]
          border.set_char Border::CharPosition::Vertical, resolved[5]
        when 3 # corner group, horizontal runs, vertical runs
          border.set_char Border::CharPosition::Corner, resolved[0]
          border.set_char Border::CharPosition::Horizontal, resolved[1]
          border.set_char Border::CharPosition::Vertical, resolved[2]
        when 1 # one char everywhere
          border.set_char Border::CharPosition::Corner, resolved[0]
          border.set_char Border::CharPosition::Horizontal, resolved[0]
          border.set_char Border::CharPosition::Vertical, resolved[0]
        end
      end

      # Resolves *value* to a color and yields it to *block*, but drops a blank
      # value rather than letting it clobber the color. A `var(--x)` whose custom
      # property is undefined collapses to "" before reaching here (the cascade
      # resolves `var()` first), and running that through `Colors.convert` maps to
      # the `-1` terminal-default sentinel — silently resetting a color a
      # lower-priority rule had set. CSS drops such an invalid declaration instead,
      # leaving the cascaded color intact (same guard as `z-index`/`visibility`/
      # `display`). `transparent` resolves to a genuine `-1` `Int32`, not a blank
      # string, so it's unaffected.
      #
      # A non-blank but malformed color *function* is likewise dropped: an
      # `rgb()`/`hsl()` whose argument list doesn't parse (e.g. `rgb(var(--x), 0,
      # 0)` with an undefined `var()`) resolves to `nil`, and yielding that would
      # unset a color a lower-priority rule had set. But the genuine-unset keyword
      # forms (`inherit`/`initial`/`unset`, `currentColor` with no text color) also
      # resolve to `nil` and *should* reset the color so cascade inheritance can
      # refill it — so only a failed `rgb`/`hsl` function is dropped, told apart by
      # its leading function name.
      private def self.with_color(value : String, current : Int32?, & : (Int32 | String | Nil) ->) : Nil
        return if value.blank?
        resolved = ColorValue.resolve(value, current)
        return if resolved.nil? && color_function?(value)
        yield resolved
      end

      # Whether *value* is (an attempt at) an `rgb()`/`hsl()` color function —
      # used by `with_color` to tell a malformed-function `nil` (drop it) apart
      # from a genuine-unset keyword `nil` (`inherit`/`currentColor`, reset it).
      private def self.color_function?(value : String) : Bool
        # Reached only on the rare resolve-`nil` path. CSS function names are
        # case-insensitive (`RGB(...)` == `rgb(...)`), matching `ColorValue.resolve`.
        v = value.lstrip
        head = v[0, 3].downcase
        head == "rgb" || head == "hsl"
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

      # Applies the `border-color` shorthand: 1-4 colors in CSS TRBL order
      # (`border-color: <top> <right> <bottom> <left>`), with the standard CSS
      # fill-ins (1 value → whole border; 2 → vertical/horizontal; 3 → top/
      # horizontal/bottom). A single color recolors the whole border and clears
      # any per-side override (`border-top-color` & co.) — the renderer reads
      # `top_fg = @top_fg || @fg`, so a stale `@top_fg` would otherwise shadow the
      # new whole-border `@fg`. Two-to-four colors set the per-side
      # `top_fg`/`right_fg`/… slots directly, the analog of the multi-value
      # `border-width` shorthand (`apply_border_width`).
      #
      # Tokens are split with `split_top_level` so a color function's internal
      # spaces/commas (`rgb(255, 0, 0)`) stay one token (a plain split would break
      # them apart and resolve to the `-1` "unknown" sentinel, dropping all
      # colors). A blank value or one with more than four colors is dropped.
      private def self.apply_border_color(border : Border, value : String, el_color : Int32?) : Nil
        return if value.blank?
        tokens = split_top_level(value)
        if tokens.size == 1
          # Whole-border recolor: keep the resolved form (`Int32`/`String`) via
          # `Colorizable`, and clear any per-side override so it can't shadow it.
          with_color(value, el_color) do |c|
            border.fg = c
            border.top_fg = border.right_fg = border.bottom_fg = border.left_fg = nil
          end
          return
        end
        # Resolve each token to the native per-side int form (`currentColor`
        # against the element's text color, like the per-side longhands).
        c = tokens.map { |token| coerce_color_int(ColorValue.resolve(token, el_color)) }
        return unless i = trbl_indices(tokens.size) # 0 (blank) / >4 colors: drop it
        border.top_fg = c[i[:top]]
        border.right_fg = c[i[:right]]
        border.bottom_fg = c[i[:bottom]]
        border.left_fg = c[i[:left]]
      end

      # Maps the number of values in a CSS TRBL shorthand (`border-width`,
      # `border-color`, `padding`, `margin`, ...) to the source-token index for
      # each of top/right/bottom/left, implementing CSS's fill-in rule in one
      # place: 1 value → all sides; 2 → vertical/horizontal; 3 → top/horizontal/
      # bottom; 4 → top/right/bottom/left. Returns `nil` for an empty (0) or
      # over-long (>4) value, which is invalid and should be dropped by the caller.
      private def self.trbl_indices(count : Int32) : NamedTuple(top: Int32, right: Int32, bottom: Int32, left: Int32)?
        case count
        when 1 then {top: 0, right: 0, bottom: 0, left: 0}
        when 2 then {top: 0, right: 1, bottom: 0, left: 1} # vertical horizontal
        when 3 then {top: 0, right: 1, bottom: 2, left: 1} # top horizontal bottom
        when 4 then {top: 0, right: 1, bottom: 2, left: 3} # top right bottom left
        else        nil
        end
      end

      # Maps a CSS `border-style` keyword to a `BorderType`, or `nil` if the
      # token isn't a style keyword (a width, color, or `none`). `solid`/`line`
      # both mean the light line border; `bg`/`background` the fill-char border;
      # `dashed`/`dotted`/`double` their respective glyph sets; `rounded` (or
      # `round` — no standard CSS spelling exists) the arc-corner family.
      private def self.border_type_keyword(token : String) : BorderType?
        case Case.fold_keyword(token)
        when "solid", "line"    then BorderType::Solid
        when "dashed"           then BorderType::Dashed
        when "dotted"           then BorderType::Dotted
        when "double"           then BorderType::Double
        when "rounded", "round" then BorderType::Rounded
        when "bg", "background" then BorderType::Fill
        else                         nil
        end
      end

      # A single-side `border-<side>` shorthand: a width sets that side, a style
      # keyword sets the border type (or hides the side with `none`), and any
      # other token is the color for that side — routed to the per-side
      # `border-<side>-color` slot (`top_fg`/`left_fg`/…), not the whole-border
      # `fg`. So `border-left: solid red` colors only the left edge, matching CSS.
      # *el_color* is the element's text color, the basis for `currentColor`
      # (see `apply_border`).
      private def self.apply_border_side(border : Border, side : Side, value : String, el_color : Int32?) : Nil
        vertical = side.top? || side.bottom?
        # A width token (if any) is authoritative for the side; a bare style
        # keyword only ensures visibility when no width was given. A width is
        # honored at its rounded cell count (`0.04em`/`1px` → 0, `1.5em` → 2), so
        # a sub-cell hairline collapses to no border instead of being forced to a
        # full-cell box by an accompanying `solid`. (Unlike the `border-width`
        # longhand, a shorthand width is not clamped up.)
        explicit_width = nil
        type_seen = false
        # Split on top-level whitespace only, so a color function's internal
        # spaces/commas (`rgb(30, 30, 46)`) stay one token — same tokenizing as
        # `parse_border`/`apply_border_color`. A plain `value.split` would break a
        # multi-token color into fragments that each resolve to the `-1` "unknown"
        # sentinel, mis-setting the per-side color.
        split_top_level(value).each do |token|
          if Case.fold_keyword(token) == "none"
            explicit_width = 0
          elsif type = border_type_keyword(token)
            border.type = type
            type_seen = true
          elsif nw = named_width(token)
            # Named width (`thin`/`medium`/`thick`) before the color fallback, so
            # `border-left: thin solid red` sets a 1-cell edge, not a bogus color.
            explicit_width = nw
          elsif w = Length.to_cells(token, vertical)
            explicit_width = w
          else
            set_side_color border, side, ColorValue.resolve(token, el_color)
          end
        end
        if explicit_width
          set_side border, side, explicit_width
        elsif type_seen
          ensure_side border, side
        end
      end

      # A `border-<side>-color` longhand: resolves *value* (dropping a blank or
      # malformed color, per `with_color`) and routes it to that side's per-side
      # color slot via `set_side_color` — the same per-side dispatch the
      # `border-<side>` shorthand uses, rather than four inline copies.
      private def self.apply_side_color(border : Border, side : Side, value : String, el_color : Int32?) : Nil
        with_color(value, el_color) { |c| set_side_color border, side, c }
      end

      # Sets the per-side border color (`top_fg`/`right_fg`/`bottom_fg`/`left_fg`)
      # for the `border-<side>` shorthand and the `border-<side>-color` longhand
      # (via `apply_side_color`), coercing the resolved color to the native int
      # form those slots store.
      private def self.set_side_color(border : Border, side : Side, resolved : Int32 | String | Nil) : Nil
        border.set_color side, coerce_color_int(resolved)
      end

      # Applies the `border-width` shorthand: 1-4 cell widths in CSS TRBL order
      # (`border-width: <top> <right> <bottom> <left>`), with the standard CSS
      # fill-ins (1 value → all sides; 2 → vertical/horizontal; 3 → top/horizontal/
      # bottom). Each side resolves through `border_cells` (same per-axis scaling
      # as `border-top-width`/`border-bottom-width`), and a sub-cell width clamps
      # up to 1 so a declared border stays visible — e.g. `border-width: 0 0 1px 0`
      # gives a 1-cell bottom edge only.
      #
      # A blank value or one with more than four widths is invalid CSS and
      # dropped, leaving the border unchanged (mirrors `parse_sides`).
      private def self.apply_border_width(border : Border, value : String) : Nil
        # Split on top-level whitespace only, so a `calc(...)` width whose
        # internal `+`/`-` carry required spaces (`calc(2em + 1px)`) stays one
        # token — same tokenizing as the `border-color`/`border-<side>` shorthands.
        tokens = split_top_level(value)
        # A cell is taller than wide, so horizontal (left/right) and vertical
        # (top/bottom) axes resolve absolute units differently — resolve each
        # token on both axes and pick the right one per side.
        h = tokens.map { |token| border_cells(token) }
        v = tokens.map { |token| border_cells(token, vertical: true) }
        # 0 (blank/invalid) or >4 widths: invalid declaration, drop it. Top/bottom
        # read the vertical-axis cells, left/right the horizontal-axis cells.
        return unless i = trbl_indices(tokens.size)
        border.top = v[i[:top]]
        border.right = h[i[:right]]
        border.bottom = v[i[:bottom]]
        border.left = h[i[:left]]
      end

      # Applies a `border-style` keyword to the given *sides*: `none` hides them,
      # any line/fill keyword (`solid`/`line`/`dashed`/`dotted`/`double`/`bg`)
      # sets the type and enables the sides.
      private def self.apply_border_style(border : Border, value : String, sides : Tuple) : Nil
        # CSS `border-style` accepts 1–4 space-separated keywords (TRBL). `Border#type`
        # is whole-border (no per-side type), so honor the *first* token rather
        # than folding the whole multi-value string and matching nothing — which
        # silently dropped the declaration.
        first = value.strip.split.first?
        return unless first
        if Case.fold_keyword(first) == "none"
          sides.each { |side| set_side border, side, 0 }
        elsif type = border_type_keyword(first)
          border.type = type
          sides.each { |side| ensure_side border, side }
        end
      end

      private def self.set_side(border : Border, side : Side, width : Int32) : Nil
        border.set_width side, width
      end

      # Ensures a side has at least width 1 (so a `solid` style makes it visible).
      private def self.ensure_side(border : Border, side : Side) : Nil
        set_side border, side, 1 if border.width_of(side) == 0
      end

      # Resolves a CSS `font-weight` to the terminal's single bold attribute.
      # Beyond `bold`/`normal`, also honors numeric weights (`font-weight: 700`)
      # and the relative `bolder`/`lighter`. The numeric cutoff matches Qt's
      # (`QFont#bold` is `weight > Medium(500)`): over 500 is bold, 100..500 and
      # `normal`/`lighter` are not. An unrecognized value leaves the weight unchanged.
      private def self.font_weight_bold(value : String, current : Bool) : Bool
        case v = Case.fold_keyword(value.strip)
        when "bold", "bolder"    then true
        when "normal", "lighter" then false
        else
          (w = v.to_i?) ? w > 500 : current
        end
      end

      # Resolves a CSS `font-style` value to the terminal's single slant
      # attribute. Both `italic` and `oblique` slant, `normal` is upright, and an
      # unrecognized value leaves the slant unchanged.
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

      # Maps a CSS named border width (`thin`/`medium`/`thick`) to a cell count,
      # or `nil` for any other token. Per CSS `thin < medium < thick`; in the
      # terminal cell model `thin`/`medium` both round to a single-cell line and
      # `thick` to two. Checked before the length/color parsing in the `border`
      # shorthand and the width resolvers, so these keywords aren't mistaken for
      # a color (`border: thin solid red` would otherwise set the border color to
      # the unknown-name `-1` sentinel or, in the shorthand, drop the width to 0).
      private def self.named_width(token : String) : Int32?
        case Case.fold_keyword(token.strip)
        when "thin", "medium" then 1
        when "thick"          then 2
        else                       nil
        end
      end

      # Like `cells`, but a positive sub-cell width (e.g. `2px` with the default
      # `px` divisor, which rounds to 0) clamps up to 1 so a declared border
      # doesn't vanish. An explicit `0`, negative width, or non-length value
      # still yields 0.
      #
      # A border width is almost always a bare number or one unit'd length, so
      # resolve the fractional cells in one pass (`to_cells_f`) and clamp from it.
      # Only a rare `calc()` border falls back to `to_cells`.
      private def self.border_cells(value : String, vertical : Bool = false) : Int32
        border_cells?(value, vertical) || 0
      end

      # Nilable variant of `border_cells`: returns `nil` when the value is not a
      # length or named width *at all* (a blank/collapsed `var(--x)` or a typo
      # like `thinn`), so a caller can drop the invalid declaration rather than
      # hard-resetting the side to 0 — matching every sibling longhand
      # (`padding-left`, `tab-size`, `border-top-style`). A genuine `0`, negative,
      # or sub-cell length still resolves to a real cell count (0 / clamp-up).
      private def self.border_cells?(value : String, vertical : Bool = false) : Int32?
        if nw = named_width(value)
          return nw
        end
        if frac = Length.to_cells_f(value, vertical)
          cells = Length.to_cell_count(frac)
          return cells if cells > 0
          return frac > 0 ? 1 : 0 # positive sub-cell width → keep it visible; 0 / negative → none
        end
        c = Length.to_cells(value, vertical) # a `calc()` border still resolves here
        return nil unless c                  # nothing parsed → invalid declaration, dropped by caller
        c > 0 ? c : 0
      end

      # Parses a `box-shadow`. `none` disables the shadow; otherwise a default
      # drop shadow is enabled, and a bare fractional `0..1` number anywhere in
      # the value is taken as its opacity. The full CSS offset/blur/spread/color
      # syntax is accepted but only its presence (and optional opacity) is
      # honored.
      #
      # The opacity token must carry a decimal point to tell an opacity (`0.3`)
      # apart from an integer length offset — otherwise `box-shadow: 0 4px 8px
      # <color>` would read its `0` offset as opacity `0`, an invisible shadow.
      # It must also lie *outside* the offset run: the leading length tokens are
      # the geometry fields (offset-x, offset-y, blur, spread), so a fractional
      # value there (`0.0 4px 8px black`, `0.5 0.5 black`) is an offset, not
      # opacity.
      private def self.parse_box_shadow(value : String) : Shadow
        return Shadow.from(false) if Case.fold_keyword(value.strip) == "none"
        toks = value.split
        # Count the leading run of length/number tokens (up to the 4 geometry
        # slots). A number within this run is always a geometry offset.
        offsets = 0
        toks.each do |t|
          break unless length_token?(t)
          offsets += 1
          break if offsets >= 4
        end
        # A CSS offset spec needs *both* offset-x and offset-y, so a lone leading
        # length isn't a coordinate — it's crysterm's bare-fractional opacity
        # shorthand (`box-shadow: 0.3`). Only a run of >= 2 lengths is offsets.
        offsets = 0 if offsets < 2
        # Opacity is a unitless fractional 0..1 *outside* that run (e.g. after
        # the color). Unit'd lengths (`0.5px`) fail `to_f?` and are excluded
        # anyway.
        opacity = nil
        toks.each_with_index do |t, i|
          next if i < offsets
          if (num = t.to_f?) && t.includes?('.') && 0.0 <= num <= 1.0
            opacity = num
            break
          end
        end
        opacity ? Shadow.from(opacity) : Shadow.from(true)
      end

      # Whether a `box-shadow` token occupies a geometry (offset/blur/spread) slot,
      # i.e. begins like a number or length rather than a color name or keyword.
      private def self.length_token?(t : String) : Bool
        return false if t.empty?
        c = t[0]
        c.ascii_number? || c == '.' || c == '-' || c == '+'
      end

      # Resolves the shared CSS `padding`/`margin` 1-4 value shorthand (CSS TRBL
      # order) into `{left, top, right, bottom}` cell counts, or `nil` for an
      # empty/over-long value. Each shorthand value maps to a horizontal
      # (left/right) and a vertical (top/bottom) slot, which scale absolute units
      # differently — so both axes are resolved and the right one is picked per
      # side.
      private def self.parse_sides(value : String) : Tuple(Int32, Int32, Int32, Int32)?
        # Split on top-level whitespace only, so a `calc(...)` value whose
        # internal `+`/`-` carry required spaces (`calc(2em + 1px)`) stays one
        # token instead of being shredded into three bogus "sides". Same
        # tokenizing as the color shorthands.
        parts = split_top_level(value)
        h = parts.map { |part| cells(part) }
        v = parts.map { |part| cells(part, vertical: true) }
        # left/right read the horizontal-axis cells, top/bottom the vertical-axis
        # cells; `nil` for an empty (0) or over-long (>4) value.
        return nil unless i = trbl_indices(parts.size)
        {h[i[:left]], v[i[:top]], h[i[:right]], v[i[:bottom]]}
      end

      # Parses the CSS `padding` shorthand (1-4 cell values, CSS TRBL order)
      # into a `Padding`.
      private def self.parse_padding(value : String) : Padding
        if sides = parse_sides(value)
          # Negative padding is an invalid CSS declaration; clamp each resolved
          # side to >= 0 (margin, which shares parse_sides, keeps negatives).
          l, t, r, b = sides
          Padding.new(Math.max(0, l), Math.max(0, t), Math.max(0, r), Math.max(0, b))
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
      # border), and otherwise treats a token as a color — resolved through
      # `ColorValue` exactly like the `border-color` longhand, so `currentColor`
      # and color functions (`rgb()`/`hsl()`/gradients) work here too. Tokens are
      # split with `split_top_level` so a function's internal spaces/commas
      # (`rgb(255, 0, 0)`) stay one token.
      private def self.parse_border(value : String, el_color : Int32? = nil) : Border
        return Border.new(0) if Case.fold_keyword(value.strip) == "none"
        border = Border.new # default: line border, 1 cell on each side
        split_top_level(value).each do |token|
          if type = border_type_keyword(token)
            border.type = type
          elsif nw = named_width(token)
            # A named width (`thin`/`medium`/`thick`) sizes all four sides; must
            # be checked before the color fallback so it isn't treated as an
            # unknown color name.
            border.left = border.right = border.top = border.bottom = nw
          elsif w = Length.to_cells(token)
            # One width for all four sides, honored at its rounded cell count
            # rather than clamping a sub-cell hairline up to a full-cell box.
            # (top/bottom scale absolute units differently.)
            border.left = border.right = w
            border.top = border.bottom = (Length.to_cells(token, vertical: true) || w)
          else
            # Whole-border color: keep the resolved form (`Int32`/`String`) via
            # `Colorizable`. A `nil` (`inherit`/`initial`/`currentColor` with no
            # text color) is dropped so it doesn't clobber the color with "unset".
            # A named/hex string that `Colors.convert` can't recognize collapses
            # to the `-1` sentinel (a stray keyword — e.g. a misspelled width);
            # drop it too rather than storing a bogus border color. `transparent`
            # resolves to a genuine `Int32` `-1` and is kept.
            resolved = ColorValue.resolve(token, el_color)
            if resolved.is_a?(String)
              border.fg = resolved unless Colors.convert_cached(resolved) == -1
            elsif resolved
              border.fg = resolved
            end
          end
        end
        border
      end
    end
  end
end
