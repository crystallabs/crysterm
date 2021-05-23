require "./node"
require "./element"
require "./box"

module Crysterm
  module Widget
    class BigText < Widget::Box

      # TODO Why these two default values generate an error (not initialized) if removed?
      property font : String = "#{__DIR__}/../fonts/ter-u14n.json"
      property font_bold : String = "#{__DIR__}/../fonts/ter-u14b.json"

      property ratio : Tput::Size = Tput::Size.new 0, 0
      property text = ""

      # TODO This isn't very useful as-is.
      # Support font scaling, etc.
      # Also, character for fg/bg, etc.

      # Normal font
      property normal : Hash(String, Array(Array(Int32))) # JSON::Any

      # Bold font
      property bold : Hash(String, Array(Array(Int32))) # JSON::Any

      # Currently active font (points to normal or bold)
      property active : Hash(String, Array(Array(Int32))) # JSON::Any

      property _shrink_width : Bool = false
      property _shrink_height : Bool = false

      def initialize(
        font = "#{__DIR__}/../fonts/ter-u14n.json",
        font_bold = "#{__DIR__}/../fonts/ter-u14b.json",
        **box
      )
        #@ratio = Size.new 0, 0

        @normal = load_font font
        @bold = load_font font_bold

        box["content"]?.try do |c|
          @text = c
        end

        super **box

        if @style.try &.bold
          @active = @bold
        else
          @active = @normal
        end
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
          chs = line.chars #line.split ""
          chs = chs.map do |ch|
            (ch == ' ') ? 0 : 1
          end
          while chs.size < @ratio.width
            chs.push 0
          end
          chs
        end

        while lines.size < @ratio.height
          line = [] of Int32
          (0...@ratio.width).each do |i|
            line.push 0
          end
          lines.push line
        end

        lines
      end

      def set_content(content)
        @content = ""
        @text = content || ""
      end

      def render
        if (@position.width.nil? || @_shrink_width)
          # D O:
          # if (@width - @iwidth < @ratio.width * @text.length + 1)
          @position.width = @ratio.width * @text.size + 1
          @_shrink_width = true
          # end
        end
        if (@position.height.nil? || @_shrink_height)
          # D O:
          # if (@height - @iheight < @ratio.height + 0)
          @position.height = @ratio.height + 0
          @_shrink_height = true
          # end
        end
        coords = _render
        return unless coords

        lines = @screen.lines
        left = coords.xi + ileft
        top = coords.yi + itop
        right = coords.xl - iright
        bottom = coords.yl - ibottom

        dattr = sattr @style
        bg = dattr & 0x1ff
        fg = (dattr >> 9) & 0x1ff
        flags = (dattr >> 18) & 0x1ff
        attr = (flags << 18) | (bg << 9) | fg

        max_chars = Math.min @text.size, (right-left)//@ratio.width

        i = 0

        x = @align.right? ? (right-max_chars*@ratio.width) : left
        while i < max_chars

          ch = @text[i]?.try &.to_s
          break unless ch
          map = @active[ch]?
          unless map
            map = @active["?"]
          end
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
              mcell = mline[mx]
              break if mcell.nil?

              # TODO Disabled because currently fch doesn't exist or something? Or was renamed?
              #if (@fch && @fch != ' ')
              #  lines[y][x + mx].attr = dattr
              #  lines[y][x + mx].char = mcell == 1 ? @fch : @style.char
              #else
                lines[y][x + mx].attr = mcell == 1 ? attr : dattr
                lines[y][x + mx].char = mcell == 1 ? ' ' : @style.char
              #end

              mx += 1
            end
            lines[y].dirty = true

            y += 1
          end

          x += @ratio.width
          i += 1
        end

        coords
      end
    end
  end
end
