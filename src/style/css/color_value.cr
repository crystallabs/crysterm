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
      # (`-120 ≡ 240`), not be read as its absolute value. A negative `s`/`l`
      # simply clamps to 0. The `|\.\d+` alternative accepts a leading-dot decimal
      # (`.5`) as the whole number, so `.5turn` isn't misread as `5turn`; see
      # `Length::NUM`, which accepts the same forms.
      RGB_RE = /(#{Length::NUM})/

      # The hue argument of `hsl()`, with its optional CSS angle unit. The hue is
      # an `<angle>`, so CSS allows `deg`/`grad`/`rad`/`turn` (e.g. `hsl(0.5turn,
      # …)`); a bare number is degrees. Capturing the unit lets `#hue_degrees`
      # convert it correctly (`0.5turn` → 180°, not 0.5°). Matches the first
      # number in the value case-insensitively. The `|\.\d+` alternative accepts
      # a leading-dot decimal (`.5turn` == `0.5turn`) to avoid misreading it as
      # `5turn`.
      HUE_RE = /(#{Length::NUM})(deg|grad|rad|turn)?/i

      def self.resolve(value : String, current_fg : Int32?) : Int32 | String | Nil
        v = value.strip
        # CSS function names and keywords are case-insensitive, so dispatch on a
        # lower-cased copy (`RGB(...)`/`HSL(...)`/`LINEAR-GRADIENT(...)` are valid).
        # The parsers harvest numbers regardless of case, so they still get `v`.
        # `Case.fold_keyword` returns `v` itself (no allocation) when it is already
        # lower-case ASCII — the common case here, where every color resolves to a
        # bare `#rrggbb`/named color and this runs per color declaration per widget
        # on each cascade.
        case dv = Case.fold_keyword(v)
        when "transparent"
          -1 # terminal default
        when "currentcolor"
          current_fg
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
        else             nil
        end
      end

      # Matches a CSS/Qt gradient function head: CSS `linear-gradient(`/
      # `radial-gradient(`/`conic-gradient(` and Qt `qlineargradient(`/
      # `qradialgradient(`/`qconicalgradient(`.
      GRADIENT_HEAD = /\b[a-z]*gradient\s*\(/i

      # A color stop inside a gradient: an `rgb()/rgba()` or `hsl()/hsla()` color
      # function, a `#rgb[a]`/`#rrggbb[aa]` hex, or a bare identifier (a CSS named
      # color such as `red`/`steelblue`). Qt stops read `stop: <pos> <color>`,
      # CSS stops `<color> <pos>` — either spelling, we just harvest the colors.
      # Functions are matched first so their inner numbers/commas aren't tokenized
      # separately. A bare identifier also matches the gradient's non-color
      # keywords (`to`/`circle`/`gradient`/...) and units (`deg`), but those
      # resolve to the `-1` sentinel and are skipped in the average.
      GRADIENT_STOP = /rgba?\([^)]*\)|hsla?\([^)]*\)|#[0-9a-fA-F]{3,8}|[a-z][a-z]+/i

      # Collapses a CSS/Qt gradient to a representative solid color: a terminal
      # cell paints a flat background, so the best approximation is the
      # channel-wise average of the gradient's stop colors. Returns `nil` when
      # *value* is not a gradient or has no parseable stops.
      def self.gradient_color(value : String) : Int32?
        return nil unless value =~ GRADIENT_HEAD
        r = g = b = n = 0
        value.scan(GRADIENT_STOP) do |m|
          # Each stop resolves like any color value; the gradient's non-color
          # keywords (`to`/`circle`/`gradient`/…) and units collapse to the `-1`
          # sentinel and `solid` drops them, so they're skipped. `currentColor`
          # has no meaning in a standalone gradient, so resolve against no fg.
          next unless c = solid(m[0], nil)
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
        # `to_f?` (not strict `to_f`): a numeric literal past Float64 range
        # (309+ digits, a generated/corrupted stylesheet value) makes `to_f`
        # raise `ArgumentError` on ERANGE, and nothing between `Properties.apply`
        # and `Cascade.apply_sheets` rescues. `compact_map` drops any such token,
        # so `parse_hsl` bails to `nil` when fewer than 3 numbers remain — mirrors
        # `Length.to_cells_f`'s hardening.
        value.scan(RGB_RE).compact_map(&.[1].to_f?)
      end

      # A single `rgb()` component: an optionally-signed number with an optional
      # trailing `%`. The leading `-?` matters: a negative channel is valid input
      # and CSS clamps it to 0, so it must be read as negative and clamped by
      # `#component` rather than parsed as its magnitude (`rgb(-10, …)` is `0`,
      # not `10`). Mirrors the signed `RGB_RE` used by `#parse_hsl`, including its
      # leading-dot decimal (`.5%`).
      RGB_COMPONENT = /(#{Length::NUM})(%)?/

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
        # `to_f?`: an out-of-Float64-range channel literal must clamp to 0, not
        # raise `ArgumentError` (ERANGE) out of the cascade — same hardening as
        # `Length.to_cells_f`.
        n = m[1].to_f? || return 0
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
        # The chroma/sextant math lives once in the `term_colors` shard
        # (`Colors.hsl_to_rgb`), which returns the same packed `0xRRGGBB` this
        # method needs. `s`/`l` are already clamped to `0..1` and `h` wrapped, so
        # the shard's rounding/clamping is byte-identical to the former inline block.
        Colors.hsl_to_rgb(h, s, l)
      end

      # The `hsl()` hue in degrees, honoring the optional CSS angle unit on the
      # first argument: `turn` (1turn = 360°), `grad` (400grad = 360°), `rad`
      # (2π rad = 360°), or `deg`/unitless (already degrees). Caller wraps the
      # result into `0..360`.
      private def self.hue_degrees(value : String) : Float64
        return 0.0 unless m = value.match(HUE_RE)
        # `to_f?`: an out-of-Float64-range hue literal falls back to 0°, not a
        # raised `ArgumentError` (ERANGE) — same hardening as `Length.to_cells_f`.
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
        # if converted first, instead of being clamped to 255. (`Length#to_cell_count`
        # uses the same clamp-then-convert order for the same reason.)
        value.round.clamp(0.0, 255.0).to_i
      end

      private def self.rgb(r : Int32, g : Int32, b : Int32) : Int32
        Colors.rgb(r, g, b)
      end
    end
  end
end
