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
      # Cache for the pure (non-`currentColor`) `resolve` results, keyed by the
      # stripped value. A cascade re-runs `resolve` for the same color string
      # once per widget that shares it (40 buttons, one `#223`), and the fold +
      # `gradient`/`rgb`/`hsl` pre-scan below is otherwise uncached (only the
      # final `Colors.convert` is memoized). Bounded so a pathological sheet
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

      # `rgb()`/`hsl()` function parsing lives in the term_colors shard
      # (`parse_rgb_function`/`parse_hsl_function` — generic CSS color-function
      # grammar, not stylesheet policy); these wrappers keep the local names
      # the dispatch below uses.
      private def self.parse_rgb(value : String) : Int32?
        Colors.parse_rgb_function value
      end

      # :ditto:
      private def self.parse_hsl(value : String) : Int32?
        Colors.parse_hsl_function value
      end

      private def self.rgb(r : Int32, g : Int32, b : Int32) : Int32
        Colors.rgb(r, g, b)
      end
    end
  end
end
