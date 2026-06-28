module Crysterm
  module CSS
    # Resolves a CSS color *value* to crysterm's native form before it reaches
    # `Colors.convert`: an `Int32` (`0xRRGGBB`, or `-1` for the terminal
    # default), a `String` passed through for named/hex colors, or `nil` to
    # leave the color unset.
    #
    # Handles the CSS color functions `rgb()/rgba()/hsl()/hsla()` and the
    # keywords `transparent`, `currentColor`, `inherit`, `initial`, `unset`.
    module ColorValue
      # A signed number, as used by `hsl()`'s arguments. The leading `-?` matters
      # for the hue: a negative angle is valid CSS (`hsl(-120, …)`) and must wrap
      # (`-120 ≡ 240`) rather than be read as its absolute value (a different
      # color). A negative `s`/`l` is meaningless and simply clamps to 0. The
      # `|\.\d+` alternative accepts a CSS leading-dot decimal (`.5`) as the whole
      # number — without it `.5turn` was read as `5turn` (its `.5` losing the
      # leading dot), a different angle entirely; see `Length::NUM`, which already
      # accepts the same forms.
      RGB_RE = /(-?(?:\d+(?:\.\d+)?|\.\d+))/

      # The hue argument of `hsl()`, with its optional CSS angle *unit*. The hue is
      # an `<angle>`, so CSS lets it carry `deg`/`grad`/`rad`/`turn` (e.g.
      # `hsl(0.5turn, …)`); a bare number is degrees. Capturing the unit lets
      # `#hue_degrees` convert it, rather than reading every angle as degrees — so
      # `0.5turn` resolves to 180° (cyan), not 0.5° (red). Matches the first
      # number in the value (the `hsl(`/`hsla(` prefix has no digits), case-
      # insensitively (`0.5TURN`). The `|\.\d+` alternative accepts a leading-dot
      # decimal (`.5turn` == `0.5turn`); without it the regex matched only the
      # `5turn` *after* the dot, reading `.5turn` (180°, cyan) as `5turn`
      # (1800° ≡ 0°, red).
      HUE_RE = /(-?(?:\d+(?:\.\d+)?|\.\d+))(deg|grad|rad|turn)?/i

      def self.resolve(value : String, current_fg : Int32?) : Int32 | String | Nil
        v = value.strip
        # CSS function names and keywords are case-insensitive, so dispatch on a
        # lowercased copy (`RGB(...)`/`HSL(...)`/`LINEAR-GRADIENT(...)` are valid).
        # The parsers harvest numbers regardless of case, so they still get `v`.
        case dv = v.downcase
        when "transparent"
          -1 # terminal default (closest TUI analog to "see-through")
        when "currentcolor"
          current_fg
        when "inherit"
          # Leave unset; the cascade's color-inheritance pass fills it from the
          # parent (meaningful for `color`; a no-op for non-inherited props).
          nil
        when "initial", "unset"
          nil
        else
          if dv.includes?("gradient") && (grad = gradient_color(v))
            grad
          elsif dv.starts_with?("rgb")
            parse_rgb(v)
          elsif dv.starts_with?("hsl")
            parse_hsl(v)
          else
            v # named or #hex — let `Colors.convert` handle it
          end
        end
      end

      # Matches a CSS/Qt gradient function head: CSS `linear-gradient(`/
      # `radial-gradient(`/`conic-gradient(` and Qt `qlineargradient(`/
      # `qradialgradient(`/`qconicalgradient(`.
      GRADIENT_HEAD = /\b[a-z]*gradient\s*\(/i

      # A color stop inside a gradient: an `rgb()/rgba()` or `hsl()/hsla()` color
      # function, a `#rgb[a]`/`#rrggbb[aa]` hex, or a bare identifier (a CSS named
      # color such as `red`/`steelblue`). (Qt stops read `stop: <pos> <color>`,
      # CSS stops `<color> <pos>` — either spelling, we just harvest the colors.)
      # Functions are matched first so their inner numbers/commas aren't tokenized
      # separately. A bare identifier also matches the gradient's *non-color*
      # keywords (`to`/`circle`/`gradient`/...) and length/angle units (`deg`),
      # but those resolve to the `-1` "unknown" sentinel and are skipped — only
      # real colors contribute to the average. Without the identifier branch a
      # plain CSS gradient with named stops (`linear-gradient(red, blue)`) yielded
      # no parseable color at all and silently fell back to the terminal default.
      GRADIENT_STOP = /rgba?\([^)]*\)|hsla?\([^)]*\)|#[0-9a-fA-F]{3,8}|[a-z][a-z]+/i

      # Collapses a CSS/Qt gradient to a representative solid color: a terminal
      # cell paints a flat background, not a real gradient, so the best we can
      # display is the channel-wise average of the gradient's stop colors (a
      # blue→cyan bar reads as the blue-cyan midpoint). Returns `nil` when *value*
      # is not a gradient or has no parseable stops. This is what lets a theme
      # like breeze's `…::item:selected:active { background: qlineargradient(...) }`
      # render — rather than feeding a stray `#rrggbb,` stop token to the color
      # parser (which used to crash).
      def self.gradient_color(value : String) : Int32?
        return nil unless value =~ GRADIENT_HEAD
        r = g = b = n = 0
        value.scan(GRADIENT_STOP) do |m|
          tok = m[0]
          dv = tok.downcase
          c = if tok.starts_with?('#')
                Colors.convert_cached(tok)
              elsif dv.starts_with?("rgb") # rgb()/rgba()
                parse_rgb(tok) || -1
              elsif dv.starts_with?("hsl") # hsl()/hsla()
                parse_hsl(tok) || -1
              else # a CSS named color, or a non-color keyword (-1, skipped below)
                Colors.convert_cached(tok)
              end
          next if c < 0
          r += (c >> 16) & 0xff
          g += (c >> 8) & 0xff
          b += c & 0xff
          n += 1
        end
        return nil if n == 0
        rgb r // n, g // n, b // n
      end

      # The numeric arguments of a color function, in source order
      # (`rgb(10, 20, 30)` ⇒ `[10.0, 20.0, 30.0]`). Used by the `hsl` parser
      # (`rgb` handles per-component `%` itself, see `parse_rgb`).
      private def self.numbers(value : String) : Array(Float64)
        value.scan(RGB_RE).map(&.[1].to_f)
      end

      # A single `rgb()` component: an optionally-signed number with an optional
      # trailing `%`. The leading `-?` matters: a negative channel is valid input
      # (e.g. from a generated/animated value) and CSS clamps it to 0 — so it must
      # be read as the negative it is and clamped by `#component`, not silently
      # parsed as its magnitude (`rgb(-10, …)` is `0`, not `10`). Mirrors the
      # signed `RGB_RE` used by `#parse_hsl`, including its leading-dot decimal
      # (`.5%`) — so a fractional channel reads as `0.5`, not the `5` after the dot.
      RGB_COMPONENT = /(-?(?:\d+(?:\.\d+)?|\.\d+))(%)?/

      # `rgb(r, g, b)` / `rgba(r, g, b, a)` (commas or spaces). Each channel may
      # be a `0..255` number or a `0%..100%` percentage (CSS allows either form);
      # a `%` component is scaled to `0..255`. An out-of-range or negative channel
      # is clamped to `0..255` (see `#component`). Alpha is ignored.
      private def self.parse_rgb(value : String) : Int32?
        comps = value.scan(RGB_COMPONENT)
        return nil if comps.size < 3
        rgb component(comps[0]), component(comps[1]), component(comps[2])
      end

      # One `rgb()` channel → a `0..255` int, scaling a `%` form from `0..100`.
      private def self.component(m : Regex::MatchData) : Int32
        n = m[1].to_f
        n = n * 255.0 / 100.0 if m[2]?
        clamp n
      end

      # `hsl(h, s%, l%)` / `hsla(...)`. h is a CSS `<angle>` (see `#hue_degrees`
      # for the unit handling), s/l in percent.
      private def self.parse_hsl(value : String) : Int32?
        nums = numbers(value)
        return nil if nums.size < 3
        h = hue_degrees(value) % 360.0
        s = (nums[1] / 100.0).clamp(0.0, 1.0)
        l = (nums[2] / 100.0).clamp(0.0, 1.0)
        c = (1.0 - (2.0 * l - 1.0).abs) * s
        x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs)
        m = l - c / 2.0
        r, g, b =
          case h
          when 0...60    then {c, x, 0.0}
          when 60...120  then {x, c, 0.0}
          when 120...180 then {0.0, c, x}
          when 180...240 then {0.0, x, c}
          when 240...300 then {x, 0.0, c}
          else                {c, 0.0, x}
          end
        rgb clamp((r + m) * 255), clamp((g + m) * 255), clamp((b + m) * 255)
      end

      # The `hsl()` hue in degrees, honoring the optional CSS angle unit on the
      # first argument: `turn` (1turn = 360°), `grad` (400grad = 360°), `rad`
      # (2π rad = 360°), or `deg`/unitless (already degrees). Without this every
      # hue was read as degrees, so `hsl(0.5turn, …)` resolved to 0.5° (red)
      # instead of 180° (cyan). The caller wraps the result into `0..360`.
      private def self.hue_degrees(value : String) : Float64
        return 0.0 unless m = value.match(HUE_RE)
        n = m[1].to_f
        case m[2]?.try(&.downcase)
        when "turn" then n * 360.0
        when "grad" then n * 0.9 # 400grad == 360deg
        when "rad"  then n * 180.0 / Math::PI
        else             n # deg or unitless
        end
      end

      private def self.clamp(value : Float64) : Int32
        value.round.to_i.clamp(0, 255)
      end

      private def self.rgb(r : Int32, g : Int32, b : Int32) : Int32
        (r << 16) | (g << 8) | b
      end
    end
  end
end
