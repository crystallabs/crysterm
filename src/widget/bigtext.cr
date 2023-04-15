require "./box"

module Crysterm
  class Widget
    # Widget for displaying text in big font.
    #
    # Fonts can be converted from BDF to the required JSON format using https://github.com/chjj/ttystudio
    class BigText < Widget::Box
      property font
      property font_bold

      property ratio : Tput::Size = Tput::Size.new 0, 0
      property text = ""

      # TODO This widget isn't very useful as-is.
      # Add support font scaling, character for fg/bg, etc.

      # Normal font
      property normal : Hash(String, Array(Array(Int32))) # JSON::Any

      # Bold font
      property bold : Hash(String, Array(Array(Int32))) # JSON::Any

      # Currently active_font (points to normal or bold)
      property active_font : Hash(String, Array(Array(Int32))) # JSON::Any

      property _shrink_width : Bool = false
      property _shrink_height : Bool = false

      def initialize(
        @font = "#{__DIR__}/../fonts/ter-u14n.json",
        @font_bold = "#{__DIR__}/../fonts/ter-u14b.json",
        **box
      )
        @normal = load_font font
        @bold = load_font font_bold

        box["content"]?.try do |c|
          @text = c
        end

        super **box

        @active_font = style.bold? ? @bold : @normal
      end

      def load_font(filename)
        data = JSON.parse File.read filename
        @ratio.width = data["width"].as_i
        @ratio.height = data["height"].as_i

        font = {} of String => Array(Array(Int32))
        data.as_h.["glyphs"].as_h.each do |ch, data2|
          lines = data2.as_h.["map"].as_a.map &.as_s
          font[ch] = convert_letter ch, lines
        end

        # font.delete " "
        font
      end

      def convert_letter(ch, lines)
        while lines.size > @ratio.height
          lines.shift
          lines.pop
        end

        lines = lines.map do |line|
          chs = line.chars # line.split ""
          chs = chs.map do |ch2|
            (ch2 == ' ') ? 0 : 1
          end
          while chs.size < @ratio.width
            chs.push 0
          end
          chs
        end

        while lines.size < @ratio.height
          line = [] of Int32
          (0...@ratio.width).each do # |i|
            line.push 0
          end
          lines.push line
        end

        lines
      end

      def set_content(content : String)
        @content = ""
        @text = content || ""
      end

      def render
        if (@width.nil? || @_shrink_width)
          # D O:
          # if (awidth - iwidth < @ratio.width * @text.length + 1)
          @width = @ratio.width * @text.size + 1
          @_shrink_width = true
          # end
        end
        if (@height.nil? || @_shrink_height)
          # D O:
          # if (aheight - iheight < @ratio.height + 0)
          @height = @ratio.height
          @_shrink_height = true
          # end
        end
        coords = _render
        return unless coords

        lines = screen.lines
        left = coords.xi + ileft
        top = coords.yi + itop
        right = coords.xl - iright
        bottom = coords.yl - ibottom

        default_attr = sattr style
        bg = default_attr & 0x1ff
        fg = (default_attr >> 9) & 0x1ff
        flags = (default_attr >> 18) & 0x1ff
        attr = (flags << 18) | (bg << 9) | fg

        max_chars = Math.min @text.size, (right - left)//@ratio.width

        i = 0

        x = @align.right? ? (right - max_chars*@ratio.width) : left
        while i < max_chars
          ch = @text[i]?.try &.to_s
          break unless ch
          map = @active_font[ch]? || @active_font["?"]
          y = top
          while y < Math.min(bottom, top + @ratio.height)
            # XXX Not sure if this needs to be activated/used, or can be deleted
            # unless !lines[y]?
            #  y += 1
            #  next
            # end
            mline = map[y - top]
            next unless mline
            mx = 0
            while mx < @ratio.width
              mcell = mline[mx]?
              break if mcell.nil?

              lines[y]?.try(&.[x + mx]?).try do |cell|
                if (style.fchar != ' ')
                  cell.attr = default_attr
                  cell.char = mcell == 1 ? style.fchar : style.char
                else
                  cell.attr = mcell == 1 ? attr : default_attr
                  cell.char = mcell == 1 ? ' ' : style.char
                end
              end

              mx += 1
            end
            lines[y]?.try &.dirty = true

            y += 1
          end

          x += @ratio.width
          i += 1
        end

        coords
      end
    end

    alias Bigtext = BigText
  end
end
