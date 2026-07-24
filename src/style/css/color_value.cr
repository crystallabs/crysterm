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
      # A signed number, as used by `hsl()`'s arguments. The sign is load-bearing:
      # a negative hue angle is valid CSS (`hsl(-120, …)`) and must wrap
      # (`-120 ≡ 240`) rather than read as its magnitude; a negative `s`/`l`
      # clamps to 0. A leading-dot decimal (`.5`) is a whole number.
      RGB_RE = /(#{Length::NUM})/

      # The hue argument of `hsl()`, with its optional CSS angle unit. The hue is
      # an `<angle>`, so CSS allows `deg`/`grad`/`rad`/`turn` (`hsl(0.5turn, …)`);
      # a bare number is degrees. Capturing the unit lets `#hue_degrees` convert
      # it (`0.5turn` → 180°, not 0.5°).
      HUE_RE = /(#{Length::NUM})(deg|grad|rad|turn)?/i

      # Cache for the pure (non-`currentColor`) `resolve` results, keyed by the
      # stripped value. A cascade re-runs `resolve` for the same color string
      # once per widget that shares it (40 buttons, one `#223`), and the fold +
      # `gradient`/`rgb`/`hsl` pre-scan below is otherwise uncached — only the
      # final `Colors.convert` was memoized. Bounded so a pathological sheet
      # can't grow it without limit.
      @@resolve_cache = Cache::Bounded(String, Int32 | String?).new(Cache::COLOR_CAPACITY, "css_color_resolve", register: true)

      def self.resolve(value : String, current_fg : Int32?) : Int32 | String?
        v = value.strip
        # `currentColor` is the only value whose result depends on `current_fg`,
        # so it must bypass the by-value cache; everything else is a pure
        # function of the string. Cheap length-gated case-insensitive test,
        # before the (allocating) keyword fold, keeps it out of the cache.
        return current_fg if v.bytesize == 12 && v.compare("currentcolor", case_insensitive: true) == 0
        @@resolve_cache.fetch(v) { resolve_uncached(v) }
      end

      # The pure, cacheable core of `#resolve` (every case but `currentColor`).
      private def self.resolve_uncached(v : String) : Int32 | String?
        # CSS function names and keywords are case-insensitive, so dispatch on a
        # folded copy (`RGB(...)`/`LINEAR-GRADIENT(...)` are valid). The parsers
        # harvest numbers regardless of case, so they still get `v`.
        case dv = Case.fold_keyword(v)
        when "transparent"
          -1 # terminal default
        when "inherit"
          # Leave unset; cascade's color-inheritance pass fills it from the parent.
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

      # Resolves a CSS color *token* to a single solid `0xRRGGBB` int, or `nil`
      # when it names no paintable color. Built on `resolve`: a color function or
      # keyword hands back its `Int32`, a named/hex string is run through
      # `Colors.convert`, and anything that lands on the `-1` sentinel — the
      # unknown color, or the `transparent`/unset keywords — is dropped to `nil`.
      #
      # This *collapses* the `-1` sentinel, so a caller that must keep
      # `transparent`'s `-1` distinct (e.g. `background`, where it means "paint
      # the terminal default") has to branch that out before reaching here.
      def self.solid(token : String, current_fg : Int32?) : Int32?
        case resolved = resolve(token, current_fg)
        when Int32  then resolved == -1 ? nil : resolved
        when String then (c = Colors.convert_cached(token)) == -1 ? nil : c
        end
      end

      # Matches a CSS/Qt gradient function head: CSS `linear-gradient(`/
      # `radial-gradient(`/`conic-gradient(` and Qt `qlineargradient(`/
      # `qradialgradient(`/`qconicalgradient(`.
      GRADIENT_HEAD = /\b[a-z]*gradient\s*\(/i

      # A color stop inside a gradient: an `rgb()/rgba()` or `hsl()/hsla()` color
      # function, a `#rgb[a]`/`#rrggbb[aa]` hex, or a bare identifier (a CSS named
      # color). Qt stops read `stop: <pos> <color>`, CSS stops `<color> <pos>`;
      # either spelling works, since only the colors are harvested. Functions are
      # matched first so their inner numbers/commas aren't tokenized separately.
      GRADIENT_STOP = /rgba?\([^)]*\)|hsla?\([^)]*\)|#[0-9a-fA-F]{3,8}|[a-z][a-z]+/i

      # Collapses a CSS/Qt gradient to a representative solid color: a terminal
      # cell paints a flat background, so the best approximation is the
      # channel-wise average of the gradient's stop colors. Returns `nil` when
      # *value* is not a gradient or has no parseable stops.
      def self.gradient_color(value : String) : Int32?
        return unless value =~ GRADIENT_HEAD
        r = g = b = n = 0
        value.scan(GRADIENT_STOP) do |m|
          # The gradient's non-color keywords (`to`/`circle`/…) and units collapse
          # to the `-1` sentinel, which `solid` drops. `currentColor` has no
          # meaning in a standalone gradient, so resolve against no fg.
          next unless c = solid(m[0], nil)
          r += (c >> 16) & 0xff
          g += (c >> 8) & 0xff
          b += c & 0xff
          n += 1
        end
        return if n == 0
        rgb r // n, g // n, b // n
      end

      # The numeric arguments of a color function, in source order
      # (`rgb(10, 20, 30)` ⇒ `[10.0, 20.0, 30.0]`). Used by the `hsl` parser;
      # `rgb` handles per-component `%` itself.
      private def self.numbers(value : String) : Array(Float64)
        # `to_f?` (not strict `to_f`): an out-of-Float64-range literal must not
        # raise out of the cascade. `compact_map` drops such a token, so
        # `parse_hsl` bails to `nil` when fewer than 3 numbers remain.
        value.scan(RGB_RE).compact_map(&.[1].to_f?)
      end

      # A single `rgb()` component: an optionally-signed number with an optional
      # trailing `%`. The sign is load-bearing: CSS clamps a negative channel to
      # 0, so it must be read as negative rather than as its magnitude
      # (`rgb(-10, …)` is `0`, not `10`).
      RGB_COMPONENT = /(#{Length::NUM})(%)?/

      # `rgb(r, g, b)` / `rgba(r, g, b, a)` (commas or spaces). Each channel may
      # be a `0..255` number or a `0%..100%` percentage (CSS allows either form);
      # a `%` component is scaled to `0..255`. An out-of-range or negative channel
      # is clamped to `0..255`. Alpha is ignored.
      private def self.parse_rgb(value : String) : Int32?
        comps = value.scan(RGB_COMPONENT)
        return if comps.size < 3
        rgb component(comps[0]), component(comps[1]), component(comps[2])
      end

      # One `rgb()` channel → a `0..255` int, scaling a `%` form from `0..100`.
      private def self.component(m : Regex::MatchData) : Int32
        # `to_f?`: an out-of-Float64-range channel literal clamps to 0 rather
        # than raising out of the cascade.
        n = m[1].to_f? || return 0
        n = n * 255.0 / 100.0 if m[2]?
        clamp n
      end

      # `hsl(h, s%, l%)` / `hsla(...)`. h is a CSS `<angle>`, s/l in percent.
      private def self.parse_hsl(value : String) : Int32?
        nums = numbers(value)
        return if nums.size < 3
        h = hue_degrees(value) % 360.0
        s = (nums[1] / 100.0).clamp(0.0, 1.0)
        l = (nums[2] / 100.0).clamp(0.0, 1.0)
        Colors.hsl_to_rgb(h, s, l)
      end

      # The `hsl()` hue in degrees, honoring the optional CSS angle unit on the
      # first argument: `turn` (1turn = 360°), `grad` (400grad = 360°), `rad`
      # (2π rad = 360°), or `deg`/unitless (already degrees). Caller wraps the
      # result into `0..360`.
      private def self.hue_degrees(value : String) : Float64
        return 0.0 unless m = value.match(HUE_RE)
        # `to_f?`: an out-of-Float64-range hue literal falls back to 0°.
        n = m[1].to_f? || return 0.0
        case m[2]?.try(&.downcase)
        when "turn" then n * 360.0
        when "grad" then n * 0.9 # 400grad == 360deg
        when "rad"  then n * 180.0 / Math::PI
        else             n # deg or unitless
        end
      end

      private def self.clamp(value : Float64) : Int32
        # Clamp as a Float *before* `#to_i`: a wildly out-of-range channel
        # (`rgb(99999999999, 0, 0)`) would overflow Int32 and raise in `#to_i`
        # if converted first, instead of being clamped to 255.
        value.round.clamp(0.0, 255.0).to_i
      end

      private def self.rgb(r : Int32, g : Int32, b : Int32) : Int32
        Colors.rgb(r, g, b)
      end
    end
  end
end
