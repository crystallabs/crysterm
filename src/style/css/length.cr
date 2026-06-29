module Crysterm
  module CSS
    # Shared CSS length → terminal-cell conversion, used by both `Geometry`
    # (width/height/top/left) and `Properties` (padding/margin/border-width).
    #
    # A terminal cell is not a pixel, so each unit carries a *divisor*:
    # `cells = round(value / divisor)`. E.g. `divisors["px"] == 10.0` makes
    # `200px` → 200 / 10 = 20 cells. A unit mapped to `nil` (or absent from the
    # table) has no sensible terminal mapping; such a value — and any non-numeric
    # form like `50%` — yields `nil` so callers can ignore it. The table is
    # mutable so an app/theme can retune it at startup, e.g.
    # `Crysterm::CSS::Length.divisors["px"] = 8.0`.
    #
    # Beyond plain lengths it also understands `calc(...)` (evaluated to cells when
    # every term resolves) and the viewport units `vw/vh/vmin/vmax` (resolved
    # against the window size via `viewport_cells`, since a bare divisor can't).
    #
    # ## Cell aspect ratio
    #
    # A cell is taller than it is wide, so an *absolute* length (one that denotes a
    # real device distance: `px`/`pt`/`pc`/`cm`/`mm`/`in`) spans fewer cells
    # vertically than the same length does horizontally. The divisor table anchors
    # the **horizontal** mapping (`1 cell ≈ 10px` *wide*); a vertical absolute
    # length additionally divides by `cell_aspect_ratio` (cell height ÷ width), so
    # a `200px × 200px` box comes out square on window rather than as a 2:1-tall
    # rectangle. Relative units (`em`/`rem`/`ch`/`ex`) are defined in cell terms and
    # map identically on both axes. The ratio defaults to `2.0` and is replaced by
    # the terminal's measured cell size (or `css.cell_aspect_ratio`) in
    # `apply_config`.
    module Length
      # Absolute/physical length units — those denoting a real device distance
      # rather than a count of cells. Only these are scaled by `cell_aspect_ratio`
      # on the vertical axis; the relative units (`em`/`rem`/`ex`/`ch`) are not.
      PHYSICAL = Set{"px", "pt", "pc", "cm", "mm", "in"}

      # Cell height ÷ width: how many times taller a cell is than wide. Scales the
      # divisor of an absolute unit on the *vertical* axis (see the module docs).
      # Defaults to the common `2.0`; the Window replaces it at startup with the
      # terminal's measured cell size (`Window#detect_cell_geometry`), and an
      # explicit `css.cell_aspect_ratio` config pins it (`apply_config`).
      class_property cell_aspect_ratio : Float64 = 2.0

      # Anchored on `1 cell ≈ 10px`; the on-window absolute units below are
      # *derived* from the fixed CSS ratios (`1in = 96px = 72pt = 6pc`) so they all
      # agree with one another, instead of being picked independently. Relative
      # units use the TUI conventions: `1ch ≡ 1 cell` (width of `0`), `1em/1rem ≈
      # 1 cell`, `1ex ≈ ½em → 2/cell`. The *physical* units (`cm`/`mm`/`in`) have
      # no meaning on a terminal that has no physical size, so they stay dropped
      # (map them to a number to opt in).
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

      # Seeds the divisor table from the `css.unit_divisors` / `css.px_per_cell`
      # config options — but only for whichever an app actually set (env / file /
      # CLI / API); an untouched option leaves the table alone, so a programmatic
      # `divisors[...]` tweak still stands. The `css.unit_divisors` comma map is
      # applied first, then the `css.px_per_cell` shortcut wins for `px`. Called
      # once per `Window` at startup; idempotent, so calling it again is harmless.
      def self.apply_config : Nil
        if config_set?("css.unit_divisors")
          merge_divisor_spec(Superconf.css_unit_divisors)
        end
        if config_set?("css.px_per_cell")
          divisors["px"] = Superconf.css_px_per_cell
        end
        # An explicit `css.cell_aspect_ratio` pins the ratio; otherwise the Window
        # feeds in the terminal's measured value (see `Window#detect_cell_geometry`),
        # and absent both the `2.0` default stands.
        if config_set?("css.cell_aspect_ratio")
          self.cell_aspect_ratio = Superconf.css_cell_aspect_ratio
        end
      end

      # Whether `css.cell_aspect_ratio` was explicitly configured. The Window uses
      # this to skip terminal cell-size detection when the ratio is already pinned.
      def self.cell_aspect_ratio_configured? : Bool
        config_set?("css.cell_aspect_ratio")
      end

      # Whether a config option carries a non-default value (i.e. an app actually
      # configured it). Compared as the rendered string so it works for any option
      # type; a value equal to the default is treated as unconfigured, so it never
      # overrides a programmatic `divisors[...]` tweak (and tests stay isolated).
      private def self.config_set?(key : String) : Bool
        opt = Superconf[key]
        opt.stringify != opt.default_string
      end

      # Parses a `"px=10,pt=7.5,cm=none"` map and merges it onto `divisors`: a
      # positive number sets the unit, `none`/`nil`/`drop` maps it to `nil`
      # (ignored), and any malformed entry is skipped — parsing is non-fatal.
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

      # A CSS number: an integer, a fixed-point (`1.5`), or — per the CSS grammar —
      # a *leading-dot* decimal (`.5`), optionally signed. Shared by the patterns
      # below so every length entry point accepts the same numeric forms.
      NUM = /-?(?:\d+(?:\.\d+)?|\.\d+)/
      # Splits a `<number><unit>` length into number + (letters-only) unit. `%`
      # forms are intentionally excluded so they pass through to the positioner.
      PATTERN = /\A(#{NUM})([a-z]+)\z/i
      # A bare, unit-less number (cells).
      NUMBER = /\A#{NUM}\z/
      # `calc(<expr>)`, capturing the inner expression.
      CALC = /\Acalc\(\s*(.*?)\s*\)\z/i
      # A viewport-relative length, resolved against the window by `viewport_cells`.
      # CSS units are case-insensitive (`10VW`/`10VMIN`), so this matches any
      # casing; `viewport_cells` lower-cases the captured unit before dispatch.
      VIEWPORT = /\A(#{NUM})(vw|vh|vmin|vmax)\z/i

      # Rounds fractional cells to an `Int32`, *clamping* into range so an absurd
      # length (`99999999999px`) can't raise `OverflowError` — the contract is
      # never-raises, and a value past the window is meaningless anyway.
      def self.to_cell_count(cells : Float64) : Int32
        cells.round.clamp(Int32::MIN.to_f64, Int32::MAX.to_f64).to_i
      end

      # Cells for a bare integer (`5` → 5), a unit'd length (`200px` → 20 with the
      # default table), or a `calc(...)` whose terms all resolve; `nil` for an
      # unmapped/`nil`-mapped unit (`3cm`), a viewport unit (use `viewport_cells`),
      # or any non-cell form (`50%`, `center`, junk). Never raises.
      def self.to_cells(value : String, vertical : Bool = false) : Int32?
        s = value.strip
        # `to_cells` is the most-called length entry point. Only `calc(...)` needs
        # the heavier CALC regex, so gate it on a case-insensitive first-byte
        # check (`| 0x20` lowercases an ASCII letter) — every plain number/length
        # skips the regex entirely.
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
        # Fast path for a bare integer (`5`, `0`, `-3`) — the common case — with no
        # regex. Only a bare *decimal* (`5.5`) needs the NUMBER regex, and only a
        # unit'd length needs PATTERN.
        if i = s.to_i?
          i.to_f
        elsif s.matches?(NUMBER)
          s.to_f
        elsif m = s.match(PATTERN)
          # Look the unit up as-captured first (almost always already lowercase),
          # only allocating a `downcase` copy on the rare uppercase unit.
          u = m[2]
          divisors.fetch(u) { divisors[u.downcase]? }.try do |div|
            # A vertical absolute length spans fewer cells than the same horizontal
            # one (a cell is taller than wide), so scale its divisor by the cell
            # aspect ratio. Relative units stay isotropic and are left untouched.
            div *= cell_aspect_ratio if vertical && (PHYSICAL.includes?(u) || PHYSICAL.includes?(u.downcase))
            m[1].to_f / div
          end
        end
      end

      # True if *value* is a viewport-relative length (`vw/vh/vmin/vmax`), which
      # only `viewport_cells` (given the window size) can resolve.
      def self.viewport?(value : String) : Bool
        value.strip.matches?(VIEWPORT)
      end

      # Resolves a viewport-relative length against the window size: `50vw` → half
      # the window width, `50vh` → half the height, `vmin`/`vmax` against the
      # smaller/larger side. `nil` if *value* isn't a viewport unit.
      def self.viewport_cells(value : String, screen_width : Int32, screen_height : Int32) : Int32?
        return unless m = value.strip.match(VIEWPORT)
        basis = case Case.fold_unit(m[2]) # CSS units are case-insensitive (`10VW`)
                when "vw"   then screen_width
                when "vh"   then screen_height
                when "vmin" then {screen_width, screen_height}.min
                else             {screen_width, screen_height}.max
                end
        to_cell_count(basis * m[1].to_f / 100.0)
      end

      # Evaluates a `calc()` body (the text inside the parens) to cells, honoring
      # `+ - * /` and nested parens; each length term is converted to cells first,
      # so `calc(200px + 2em)` → 20 + 2 → 22. Returns `nil` if the expression is
      # malformed or references a value that needs layout context (`%`, viewport
      # units) — the caller then ignores the declaration.
      def self.calc(body : String, vertical : Bool = false) : Int32?
        CalcEval.new(body, vertical).result.try { |f| to_cell_count(f) }
      end

      # Recursive-descent evaluator for `calc()` bodies. Internal to `Length`.
      # Tokenizes into numbers/lengths and the operators `+ - * / ( )`, then walks
      # a standard precedence grammar. Any unresolvable term (a `%`, a viewport
      # unit, a dropped unit) or malformed input raises `Error`, which `result`
      # turns into `nil` so callers ignore the value rather than crash.
      private class CalcEval
        class Error < Exception
        end

        # One token: a number/length (`12`, `1.5`, `200px`, `50%`) or an operator
        # / paren. Whitespace between tokens is simply skipped (unmatched).
        TOKEN = /[0-9]*\.?[0-9]+[a-z%]*|[-+*\/()]/i

        @tokens : Array(String)
        @pos = 0

        def initialize(body : String, @vertical : Bool = false)
          @tokens = body.scan(TOKEN).map(&.[0])
        end

        def result : Float64?
          return nil if @tokens.empty?
          value = expression
          return nil unless @pos == @tokens.size # trailing junk
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
