module Crysterm
  module CSS
    # Shared CSS length → terminal-cell conversion, for geometry
    # (width/height/top/left) and box properties (padding/margin/border-width).
    #
    # A terminal cell is not a pixel, so each unit carries a *divisor*:
    # `cells = round(value / divisor)`. E.g. `divisors["px"] == 10.0` makes
    # `200px` → 20 cells. A unit mapped to `nil` (or absent) has no sensible
    # terminal mapping; such a value — and any non-numeric form like `50%` —
    # yields `nil` so callers can ignore it. Mutable, so an app/theme can retune
    # it at startup, e.g. `Crysterm::CSS::Length.divisors["px"] = 8.0`.
    #
    # Also understands `calc(...)` (evaluated to cells when every term resolves)
    # and viewport units `vw/vh/vmin/vmax` (resolved against window size via
    # `viewport_cells`, since a bare divisor can't).
    #
    # ## Cell aspect ratio
    #
    # A cell is taller than wide, so an *absolute* length (`px`/`pt`/`pc`/`cm`/
    # `mm`/`in`) spans fewer cells vertically than horizontally. The divisor
    # table anchors the **horizontal** mapping (`1 cell ≈ 10px` wide); a
    # vertical absolute length additionally divides by `cell_aspect_ratio`
    # (height ÷ width), so a `200px × 200px` box comes out square rather than
    # 2:1-tall. Relative units (`em`/`rem`/`ch`/`ex`) map identically on both
    # axes. Ratio defaults to `2.0`, replaced by the terminal's measured cell
    # size (or `css.cell_aspect_ratio`) in `apply_config`.
    module Length
      # Absolute/physical length units — real device distance rather than a
      # count of cells. Only these are scaled by `cell_aspect_ratio` on the
      # vertical axis; relative units (`em`/`rem`/`ex`/`ch`) are not.
      PHYSICAL = Set{"px", "pt", "pc", "cm", "mm", "in"}

      # Cell height ÷ width. Scales an absolute unit's divisor on the vertical
      # axis. Defaults to `2.0`; the Window replaces it at startup with the
      # terminal's measured cell size, unless `css.cell_aspect_ratio` pins it.
      class_property cell_aspect_ratio : Float64 = 2.0

      # Anchored on `1 cell ≈ 10px`; the `px` anchor is replaced at startup with
      # the terminal's *measured* cell width when available, unless
      # `css.px_per_cell` pins it. The absolute units are derived from the fixed
      # CSS ratios (`1in = 96px = 72pt = 6pc`) so they agree with each other.
      # Relative units use TUI conventions: `1ch ≡ 1 cell` (width of `0`),
      # `1em/1rem ≈ 1 cell`, `1ex ≈ ½em → 2/cell`. Physical units (`cm`/`mm`/
      # `in`) have no terminal meaning, so they stay dropped (map to a number to
      # opt in).
      class_property divisors : Hash(String, Float64?) = {
        "px"  => 10.0,  # anchor: 1 cell ≈ 10px  (200px → 20 cells)
        "pt"  => 7.5,   # 1pt = 1/72in = 1.333px → 7.5pt per 10px cell
        "pc"  => 0.625, # 1pc = 12pt = 16px
        "em"  => 1.0,   # 1em ≈ 1 cell
        "rem" => 1.0,
        "ex"  => 2.0, # x-height ≈ ½ em → 2 ex per cell
        "ch"  => 1.0, # 1ch ≡ 1 cell by definition
        "cm"  => nil, # physical units: no TUI mapping → dropped (set a number to enable)
        "mm"  => nil,
        "in"  => nil,
      }

      # Seeds the divisor table from `css.unit_divisors`/`css.px_per_cell`, but
      # only for whichever an app actually set; an untouched option leaves the
      # table alone so a programmatic `divisors[...]` tweak stands. Called once
      # per `Window` at startup; idempotent.
      def self.apply_config : Nil
        if config_set?("css.unit_divisors")
          merge_divisor_spec(Superconf.css_unit_divisors)
        end
        if config_set?("css.px_per_cell")
          divisors["px"] = Superconf.css_px_per_cell
        end
        # Explicit config pins the ratio; otherwise the Window feeds in the
        # terminal's measured value.
        if config_set?("css.cell_aspect_ratio")
          self.cell_aspect_ratio = Superconf.css_cell_aspect_ratio
        end
      end

      # Whether `css.cell_aspect_ratio` was explicitly configured. Lets the
      # Window skip terminal cell-size detection when already pinned.
      def self.cell_aspect_ratio_configured? : Bool
        config_set?("css.cell_aspect_ratio")
      end

      # Whether `css.px_per_cell` was explicitly configured. Lets the Window
      # skip feeding the terminal's *measured* cell width into the `px` divisor
      # when the user has already pinned it.
      def self.px_per_cell_configured? : Bool
        config_set?("css.px_per_cell")
      end

      # Fixed CSS ratios of the derived absolute units to the `px` anchor
      # (`1in = 96px = 72pt = 6pc`): divisor(pt) = divisor(px) × 72/96,
      # divisor(pc) = divisor(px) ÷ 16. Matches the defaults (`px 10 → pt 7.5,
      # pc 0.625`).
      PX_DERIVED = {"pt" => 0.75, "pc" => 0.0625}

      # Re-derives the `px`-anchored absolute units (`pt`/`pc`) from the
      # current `px` divisor, keeping them mutually consistent when the Window
      # re-anchors `px` to the terminal's measured cell width. A unit the user
      # explicitly configured via `css.unit_divisors` is left alone. The
      # opt-in physical units (`cm`/`mm`/`in`) are not touched: dropped (`nil`)
      # by default, and a user who mapped one chose their own scale.
      def self.rederive_physical_from_px : Nil
        return unless px = divisors["px"]?
        PX_DERIVED.each do |unit, ratio|
          divisors[unit] = px * ratio unless unit_configured?(unit)
        end
      end

      # Whether `css.unit_divisors` explicitly configures *unit*.
      def self.unit_configured?(unit : String) : Bool
        return false unless config_set?("css.unit_divisors")
        Superconf.css_unit_divisors.split(',').any? do |entry|
          entry.partition('=')[0].strip.downcase == unit
        end
      end

      # Whether a config option carries a non-default value. Compared as the
      # rendered string so it works for any option type; a default-equal value
      # is treated as unconfigured so it never overrides a programmatic tweak.
      private def self.config_set?(key : String) : Bool
        opt = Superconf[key]
        opt.stringify != opt.default_string
      end

      # Parses a `"px=10,pt=7.5,cm=none"` map and merges onto `divisors`: a
      # positive number sets the unit, `none`/`nil`/`drop` maps to `nil`
      # (ignored); malformed entries are skipped.
      private def self.merge_divisor_spec(spec : String) : Nil
        spec.split(',') do |entry|
          key, _, val = entry.partition('=')
          key = key.strip.downcase
          next if key.empty?
          case val = val.strip.downcase
          when "none", "nil", "drop"
            divisors[key] = nil
          else
            if (f = val.to_f?) && f > 0
              divisors[key] = f
            end
          end
        end
      end

      # A CSS number: integer, fixed-point (`1.5`), or leading-dot decimal
      # (`.5`), optionally signed. Shared by the patterns below.
      NUM = /-?(?:\d+(?:\.\d+)?|\.\d+)/
      # Splits a `<number><unit>` length into number + unit. `%` excluded so it
      # passes through to the positioner.
      PATTERN = /\A(#{NUM})([a-z]+)\z/i
      # A bare, unit-less number (cells).
      NUMBER = /\A#{NUM}\z/
      # `calc(<expr>)`, capturing the inner expression.
      CALC = /\Acalc\(\s*(.*?)\s*\)\z/i
      # A viewport-relative length. CSS units are case-insensitive (`10VW`), so
      # this matches any casing; `viewport_cells` lower-cases before dispatch.
      VIEWPORT = /\A(#{NUM})(vw|vh|vmin|vmax)\z/i

      # Rounds fractional cells to an `Int32`, clamping into range so an absurd
      # length (`99999999999px`) can't raise `OverflowError`.
      def self.to_cell_count(cells : Float64) : Int32
        cells.round.clamp(Int32::MIN.to_f64, Int32::MAX.to_f64).to_i
      end

      # Cells for a bare integer (`5` → 5), a unit'd length (`200px` → 20 with the
      # default table), or a `calc(...)` whose terms all resolve; `nil` for an
      # unmapped/`nil`-mapped unit (`3cm`), a viewport unit (use `viewport_cells`),
      # or any non-cell form (`50%`, `center`, junk). Never raises.
      def self.to_cells(value : String, vertical : Bool = false) : Int32?
        s = value.strip
        # `to_cells` is the most-called entry point. Only `calc(...)` needs the
        # heavier CALC regex, so gate on a case-insensitive first-byte check
        # (`| 0x20` lowercases an ASCII letter) — plain numbers skip the regex.
        if (b = s.byte_at?(0)) && (b | 0x20) == 'c'.ord && (m = s.match(CALC))
          calc(m[1], vertical)
        else
          to_cells_f(s, vertical).try { |f| to_cell_count(f) }
        end
      end

      # Fractional cells for a single bare number or unit'd length token, without
      # rounding; `nil` for `%`, viewport units, an unmapped unit, or junk. Used by
      # `to_cells` and the `calc()` evaluator (which rounds only the final result).
      def self.to_cells_f(value : String, vertical : Bool = false) : Float64?
        s = value.strip
        # Fast path for a bare integer (`5`, `0`, `-3`), no regex. Only a bare
        # decimal (`5.5`) needs NUMBER, only a unit'd length needs PATTERN.
        # `to_f?` (not strict `to_f`) throughout: a literal past Float64 range
        # makes `to_f` raise on ERANGE, and nothing up the cascade rescues —
        # that would break the "never raises" contract.
        if i = s.to_i?
          i.to_f
        elsif s.matches?(NUMBER)
          s.to_f?
        elsif m = s.match(PATTERN)
          # Look up as-captured first (usually already lowercase), only
          # allocating a `downcase` copy on the rare uppercase unit.
          u = m[2]
          divisors.fetch(u) { divisors[u.downcase]? }.try do |div|
            # Vertical absolute lengths span fewer cells than horizontal (cell is
            # taller than wide); relative units stay isotropic.
            div *= cell_aspect_ratio if vertical && (PHYSICAL.includes?(u) || PHYSICAL.includes?(u.downcase))
            m[1].to_f?.try { |f| f / div }
          end
        end
      end

      # True if *value* is a viewport-relative length (`vw/vh/vmin/vmax`),
      # resolved only by `viewport_cells`.
      def self.viewport?(value : String) : Bool
        value.strip.matches?(VIEWPORT)
      end

      # Resolves a viewport-relative length against the window size: `50vw` →
      # half the width, `50vh` → half the height, `vmin`/`vmax` against the
      # smaller/larger side. `nil` if *value* isn't a viewport unit.
      def self.viewport_cells(value : String, screen_width : Int32, screen_height : Int32) : Int32?
        return unless m = value.strip.match(VIEWPORT)
        basis = case Case.fold_unit(m[2]) # CSS units are case-insensitive (`10VW`)
                when "vw"   then screen_width
                when "vh"   then screen_height
                when "vmin" then {screen_width, screen_height}.min
                else             {screen_width, screen_height}.max
                end
        # `to_f?`: an out-of-Float64-range literal must yield `nil`, not raise;
        # `to_cell_count` clamps any overflowing product.
        m[1].to_f?.try { |f| to_cell_count(basis * f / 100.0) }
      end

      # Evaluates a `calc()` body to cells, honoring `+ - * /` and nested parens;
      # each length term is converted to cells first, so `calc(200px + 2em)` →
      # 20 + 2 → 22. `nil` if malformed or referencing a value needing layout
      # context (`%`, viewport units).
      def self.calc(body : String, vertical : Bool = false) : Int32?
        CalcEval.new(body, vertical).result.try { |f| to_cell_count(f) }
      end

      # Recursive-descent evaluator for `calc()` bodies. Tokenizes into
      # numbers/lengths and operators `+ - * / ( )`, then walks a standard
      # precedence grammar. Any unresolvable term or malformed input raises
      # `Error`, which `result` turns into `nil`.
      private class CalcEval
        class Error < Exception
        end

        # One token: a number/length (`12`, `1.5`, `200px`, `50%`) or an
        # operator/paren. Whitespace between tokens is skipped (unmatched).
        TOKEN = /[0-9]*\.?[0-9]+[a-z%]*|[-+*\/()]/i

        @tokens : Array(String)
        @pos = 0

        def initialize(body : String, @vertical : Bool = false)
          @tokens = body.scan(TOKEN).map(&.[0])
        end

        def result : Float64?
          return if @tokens.empty?
          value = expression
          return unless @pos == @tokens.size # trailing junk
          value
        rescue Error
          nil
        end

        private def peek : String?
          @tokens[@pos]?
        end

        private def advance : String
          tok = @tokens[@pos]? || raise Error.new
          @pos += 1
          tok
        end

        private def expression : Float64
          value = term
          while (op = peek) && (op == "+" || op == "-")
            advance
            rhs = term
            value = op == "+" ? value + rhs : value - rhs
          end
          value
        end

        private def term : Float64
          value = factor
          while (op = peek) && (op == "*" || op == "/")
            advance
            rhs = factor
            if op == "/"
              raise Error.new if rhs == 0
              value /= rhs
            else
              value *= rhs
            end
          end
          value
        end

        private def factor : Float64
          case tok = peek || raise Error.new
          when "("
            advance
            value = expression
            raise Error.new unless peek == ")"
            advance
            value
          when "+"
            advance
            factor
          when "-"
            advance
            -factor
          else
            advance
            Length.to_cells_f(tok, @vertical) || raise Error.new
          end
        end
      end
    end
  end
end
