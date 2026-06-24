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
    module Length
      class_property divisors : Hash(String, Float64?) = {
        "px"  => 10.0,
        "pt"  => 12.0,
        "pc"  =>  1.0,
        "em"  =>  1.0,
        "rem" =>  1.0,
        "ex"  =>  1.0,
        "ch"  =>  1.0,
        "cm"  => nil, # physical units: no TUI mapping → ignored (set a number to enable)
        "mm"  => nil,
        "in"  => nil,
      }

      # Splits a `<number><unit>` length into number + (letters-only) unit. `%`
      # forms are intentionally excluded so they pass through to the positioner.
      PATTERN = /\A(-?\d+(?:\.\d+)?)([a-z]+)\z/i

      # Cells for a bare integer (`5` → 5) or a unit'd length (`200px` → 20 with
      # the default table); `nil` for an unmapped/`nil`-mapped unit (`3cm`) or any
      # non-cell form (`50%`, `center`, junk). Never raises.
      def self.to_cells(value : String) : Int32?
        s = value.strip
        if i = s.to_i?
          i
        elsif m = s.match(PATTERN)
          divisors[m[2].downcase]?.try { |div| (m[1].to_f / div).round.to_i }
        end
      end
    end
  end
end
