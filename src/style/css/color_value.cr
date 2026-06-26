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
      RGB_RE = /(\d+(?:\.\d+)?)/

      def self.resolve(value : String, current_fg : Int32?) : Int32 | String | Nil
        v = value.strip
        case v.downcase
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
          if v.starts_with?("rgb")
            parse_rgb(v)
          elsif v.starts_with?("hsl")
            parse_hsl(v)
          else
            v # named or #hex — let `Colors.convert` handle it
          end
        end
      end

      # The numeric arguments of a color function, in source order
      # (`rgb(10, 20, 30)` ⇒ `[10.0, 20.0, 30.0]`). Shared by the `rgb`/`hsl`
      # parsers, which differ only in how they interpret the three components.
      private def self.numbers(value : String) : Array(Float64)
        value.scan(RGB_RE).map(&.[1].to_f)
      end

      # `rgb(r, g, b)` / `rgba(r, g, b, a)` (commas or spaces). Alpha is ignored.
      private def self.parse_rgb(value : String) : Int32?
        nums = numbers(value)
        return nil if nums.size < 3
        rgb clamp(nums[0]), clamp(nums[1]), clamp(nums[2])
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
