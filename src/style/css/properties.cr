module Crysterm
  module CSS
    # Translates CSS declarations (real CSS property names) onto a `Style`.
    #
    # Property names that have a clean CSS analog use that analog (`color`,
    # `background-color`, `font-weight`, ...). Crysterm attributes with no
    # standard CSS equivalent (e.g. `inverse`, the fill chars) are intentionally
    # *not* exposed here for now; they remain settable through the programmatic
    # `Style` API until an honest CSS spelling is chosen.
    module Properties
      # Applies a single `property: value` declaration onto *style*. Unknown
      # properties are ignored, matching CSS's forgiving behavior.
      #
      # ameba:disable Metrics/CyclomaticComplexity
      def self.apply(style : Style, property : String, value : String) : Nil
        case property
        when "color"
          style.fg = value
        when "background-color", "background"
          style.bg = value
        when "font-weight"
          style.bold = bool_keyword(value, on: "bold", off: "normal", current: style.bold?)
        when "font-style"
          style.italic = bool_keyword(value, on: "italic", off: "normal", current: style.italic?)
        when "text-decoration"
          words = value.split
          style.underline = words.includes?("underline")
          style.blink = words.includes?("blink")
        when "visibility"
          style.visible = (value != "hidden")
        when "opacity"
          value.to_f?.try { |num| style.alpha = num }
        when "tab-size"
          style.tab_size = cells(value)
        when "box-shadow"
          style.shadow = parse_box_shadow(value)
        when "padding"
          style.padding = parse_padding(value)
        when "padding-left"
          style.padding.left = cells(value)
        when "padding-top"
          style.padding.top = cells(value)
        when "padding-right"
          style.padding.right = cells(value)
        when "padding-bottom"
          style.padding.bottom = cells(value)
        when "border"
          style.border = parse_border(value)
        when "border-color"
          style.border.fg = value
        when "border-width"
          w = cells(value)
          b = style.border
          b.left = b.top = b.right = b.bottom = w
        else
          # Unknown / not-yet-supported property: ignore.
        end
      end

      # Resolves a two-valued keyword property (e.g. `font-weight: bold|normal`)
      # to a Bool, leaving the current value untouched for unrecognized inputs.
      private def self.bool_keyword(value, *, on, off, current) : Bool
        case value
        when on  then true
        when off then false
        else          current
        end
      end

      # Parses a length given in terminal cells, tolerating a unit suffix like
      # `px` (e.g. `"2"` or `"2px"` -> `2`).
      private def self.cells(value : String) : Int32
        value.gsub(/[^0-9-]/, "").to_i? || 0
      end

      # Parses a `box-shadow`. `none` disables the shadow; otherwise a default
      # drop shadow is enabled, and a bare `0..1` number anywhere in the value is
      # taken as its alpha (opacity). The full CSS offset/blur/spread/color
      # syntax is accepted but only its presence (and optional alpha) is honored.
      private def self.parse_box_shadow(value : String) : Shadow
        return Shadow.from(false) if value.strip == "none"
        alpha = value.split.compact_map(&.to_f?).find { |num| 0.0 <= num <= 1.0 }
        alpha ? Shadow.from(alpha) : Shadow.from(true)
      end

      # Parses the CSS `padding` shorthand (1-4 cell values, CSS TRBL order)
      # into a `Padding`.
      private def self.parse_padding(value : String) : Padding
        v = value.split.map { |part| cells(part) }
        case v.size
        when 1 then Padding.new(v[0], v[0], v[0], v[0])
        when 2 then Padding.new(v[1], v[0], v[1], v[0]) # L,T,R,B from V,H
        when 3 then Padding.new(v[1], v[0], v[1], v[2]) # from T,H,B
        when 4 then Padding.new(v[3], v[0], v[1], v[2]) # from T,R,B,L
        else        Padding.default
        end
      end

      # Parses a `border` shorthand. Recognizes a width (cells), a style keyword
      # (`solid`/`line` -> line border, `bg` -> background border, `none` -> no
      # border), and otherwise treats a token as a color.
      private def self.parse_border(value : String) : Border
        return Border.new(0) if value.strip == "none"
        border = Border.new # default: line border, 1 cell on each side
        value.split.each do |token|
          case token
          when "solid", "line"
            border.type = BorderType::Line
          when "bg", "background"
            border.type = BorderType::Bg
          when /\A\d+(?:px)?\z/
            w = cells(token)
            border.left = border.top = border.right = border.bottom = w
          else
            border.fg = token
          end
        end
        border
      end
    end
  end
end
