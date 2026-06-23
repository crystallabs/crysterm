module Crysterm
  module CSS
    # Pure color-space math used to *derive* a full palette from a few primary
    # colors (see `Theme`). Colors are crysterm-native `0xRRGGBB` integers; the
    # derivations work in HSL so lightening/darkening stays perceptually even.
    module ColorMath
      extend self

      # `0xRRGGBB` -> `{h (0..360), s (0..1), l (0..1)}`.
      def rgb_to_hsl(rgb : Int32) : Tuple(Float64, Float64, Float64)
        r = ((rgb >> 16) & 0xff) / 255.0
        g = ((rgb >> 8) & 0xff) / 255.0
        b = (rgb & 0xff) / 255.0
        max = {r, g, b}.max
        min = {r, g, b}.min
        l = (max + min) / 2.0
        if max == min
          return {0.0, 0.0, l} # achromatic
        end
        d = max - min
        s = l > 0.5 ? d / (2.0 - max - min) : d / (max + min)
        h = case max
            when r then (g - b) / d + (g < b ? 6.0 : 0.0)
            when g then (b - r) / d + 2.0
            else        (r - g) / d + 4.0
            end
        {(h * 60.0), s, l}
      end

      # `{h, s, l}` -> `0xRRGGBB`.
      def hsl_to_rgb(h : Float64, s : Float64, l : Float64) : Int32
        h = h % 360.0
        h += 360.0 if h < 0
        if s <= 0.0
          v = clamp_byte(l * 255.0)
          return (v << 16) | (v << 8) | v
        end
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
        (clamp_byte((r + m) * 255.0) << 16) |
          (clamp_byte((g + m) * 255.0) << 8) |
          clamp_byte((b + m) * 255.0)
      end

      # Moves a color's lightness by *delta* (positive = lighter, negative =
      # darker), clamped to `[0, 1]`. Saturation/hue are preserved.
      def adjust_lightness(rgb : Int32, delta : Float64) : Int32
        h, s, l = rgb_to_hsl(rgb)
        hsl_to_rgb(h, s, (l + delta).clamp(0.0, 1.0))
      end

      def lighten(rgb : Int32, amount : Float64) : Int32
        adjust_lightness(rgb, amount.abs)
      end

      def darken(rgb : Int32, amount : Float64) : Int32
        adjust_lightness(rgb, -amount.abs)
      end

      # Linear per-channel blend of *a* and *b*; *t* is the weight of *b*
      # (`0.0` -> a, `1.0` -> b).
      def mix(a : Int32, b : Int32, t : Float64) : Int32
        t = t.clamp(0.0, 1.0)
        ar = (a >> 16) & 0xff; ag = (a >> 8) & 0xff; ab = a & 0xff
        br = (b >> 16) & 0xff; bg = (b >> 8) & 0xff; bb = b & 0xff
        r = clamp_byte(ar + (br - ar) * t)
        g = clamp_byte(ag + (bg - ag) * t)
        bl = clamp_byte(ab + (bb - ab) * t)
        (r << 16) | (g << 8) | bl
      end

      # Relative luminance (sRGB-weighted, 0..1) — how *bright* a color reads,
      # used to choose a contrasting foreground.
      def luminance(rgb : Int32) : Float64
        r = ((rgb >> 16) & 0xff) / 255.0
        g = ((rgb >> 8) & 0xff) / 255.0
        b = (rgb & 0xff) / 255.0
        0.2126 * r + 0.7152 * g + 0.0722 * b
      end

      # Picks whichever of *dark*/*light* contrasts better against *bg*.
      def readable_on(bg : Int32, dark : Int32, light : Int32) : Int32
        luminance(bg) > 0.5 ? dark : light
      end

      # `0xRRGGBB` -> `"#rrggbb"` (the form the CSS layer parses).
      def hex(rgb : Int32) : String
        "#%06x" % (rgb & 0xFFFFFF)
      end

      private def clamp_byte(value : Float64) : Int32
        value.round.to_i.clamp(0, 255)
      end
    end
  end
end
