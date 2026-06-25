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
    # against the screen size via `viewport_cells`, since a bare divisor can't).
    module Length
      # Anchored on `1 cell ≈ 10px`; the on-screen absolute units below are
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

      # Splits a `<number><unit>` length into number + (letters-only) unit. `%`
      # forms are intentionally excluded so they pass through to the positioner.
      PATTERN = /\A(-?\d+(?:\.\d+)?)([a-z]+)\z/i
      # A bare, unit-less number (cells).
      NUMBER = /\A-?\d+(?:\.\d+)?\z/
      # `calc(<expr>)`, capturing the inner expression.
      CALC = /\Acalc\(\s*(.*?)\s*\)\z/i
      # A viewport-relative length, resolved against the screen by `viewport_cells`.
      VIEWPORT = /\A(-?\d+(?:\.\d+)?)(vw|vh|vmin|vmax)\z/i

      # Cells for a bare integer (`5` → 5), a unit'd length (`200px` → 20 with the
      # default table), or a `calc(...)` whose terms all resolve; `nil` for an
      # unmapped/`nil`-mapped unit (`3cm`), a viewport unit (use `viewport_cells`),
      # or any non-cell form (`50%`, `center`, junk). Never raises.
      def self.to_cells(value : String) : Int32?
        s = value.strip
        if m = s.match(CALC)
          calc(m[1])
        else
          to_cells_f(s).try(&.round.to_i)
        end
      end

      # Fractional cells for a single bare number or unit'd length token, without
      # rounding; `nil` for `%`, viewport units, an unmapped unit, or junk. Used by
      # `to_cells` and the `calc()` evaluator (which rounds only the final result).
      def self.to_cells_f(value : String) : Float64?
        s = value.strip
        if s.matches?(NUMBER)
          s.to_f
        elsif m = s.match(PATTERN)
          divisors[m[2].downcase]?.try { |div| m[1].to_f / div }
        end
      end

      # True if *value* is a viewport-relative length (`vw/vh/vmin/vmax`), which
      # only `viewport_cells` (given the screen size) can resolve.
      def self.viewport?(value : String) : Bool
        value.strip.matches?(VIEWPORT)
      end

      # Resolves a viewport-relative length against the screen size: `50vw` → half
      # the screen width, `50vh` → half the height, `vmin`/`vmax` against the
      # smaller/larger side. `nil` if *value* isn't a viewport unit.
      def self.viewport_cells(value : String, screen_width : Int32, screen_height : Int32) : Int32?
        return unless m = value.strip.match(VIEWPORT)
        basis = case m[2].downcase
                when "vw"   then screen_width
                when "vh"   then screen_height
                when "vmin" then {screen_width, screen_height}.min
                else             {screen_width, screen_height}.max
                end
        (basis * m[1].to_f / 100.0).round.to_i
      end

      # Evaluates a `calc()` body (the text inside the parens) to cells, honoring
      # `+ - * /` and nested parens; each length term is converted to cells first,
      # so `calc(200px + 2em)` → 20 + 2 → 22. Returns `nil` if the expression is
      # malformed or references a value that needs layout context (`%`, viewport
      # units) — the caller then ignores the declaration.
      def self.calc(body : String) : Int32?
        CalcEval.new(body).result.try(&.round.to_i)
      end

      # Recursive-descent evaluator for `calc()` bodies. Internal to `Length`.
      # Tokenizes into numbers/lengths and the operators `+ - * / ( )`, then walks
      # a standard precedence grammar. Any unresolvable term (a `%`, a viewport
      # unit, a dropped unit) or malformed input raises `Error`, which `result`
      # turns into `nil` so callers ignore the value rather than crash.
      private class CalcEval
        class Error < Exception
        end

        @tokens : Array(String)
        @pos = 0

        def initialize(body : String)
          @tokens = body.scan(/[0-9]*\.?[0-9]+[a-z%]*|[-+*\/()]/i).map(&.[0])
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
            Length.to_cells_f(tok) || raise Error.new
          end
        end
      end
    end
  end
end
