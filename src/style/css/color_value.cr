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
      # color). A negative `s`/`l` is meaningless and simply clamps to 0.
      RGB_RE = /(-?\d+(?:\.\d+)?)/

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

      # A color stop inside a gradient: a `#rgb[a]`/`#rrggbb[aa]` hex or an
      # `rgb()/rgba()` function. (Qt stops read `stop: <pos> <color>`, CSS stops
      # `<color> <pos>` — either spelling, we just harvest the colors.)
      GRADIENT_STOP = /#[0-9a-fA-F]{3,8}|rgba?\([^)]*\)/i

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
          c = tok.starts_with?('#') ? Colors.convert_cached(tok) : (parse_rgb(tok) || -1)
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

      # A single `rgb()` component: a number with an optional trailing `%`.
      RGB_COMPONENT = /(\d+(?:\.\d+)?)(%)?/

      # `rgb(r, g, b)` / `rgba(r, g, b, a)` (commas or spaces). Each channel may
      # be a `0..255` number or a `0%..100%` percentage (CSS allows either form);
      # a `%` component is scaled to `0..255`. Alpha is ignored.
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

      # `hsl(h, s%, l%)` / `hsla(...)`. h in degrees, s/l in percent.
      private def self.parse_hsl(value : String) : Int32?
        nums = numbers(value)
        return nil if nums.size < 3
        h = nums[0] % 360.0
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

      private def self.clamp(value : Float64) : Int32
        value.round.to_i.clamp(0, 255)
      end

      private def self.rgb(r : Int32, g : Int32, b : Int32) : Int32
        (r << 16) | (g << 8) | b
      end
    end
  end
end
