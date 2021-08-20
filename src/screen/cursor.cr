module Crysterm
  class Screen
    # Terminal (not mouse) cursor
    module Cursor
      include Macros

      # TODO - temporary until @cursor is moved to widget
      class Cursor < Tput::Namespace::Cursor
        property style : Style = Style.new
      end

      getter cursor = Cursor.new

      # Should all these functions go to tput?

      # Applies current cursor settings in `@cursor` to screen/display
      def apply_cursor
        c = @cursor
        if c.artificial?
          render
        else
          display.try do |d|
            d.tput.cursor_shape c.shape, c.blink
            d.tput.cursor_color c.style.bg
          end
        end
        c._set = true
      end

      # Sets cursor shape
      def cursor_shape(shape : Tput::CursorShape = Tput::CursorShape::Block, blink : Bool = false)
        @cursor.shape = shape
        @cursor.blink = blink
        @cursor._set = true
        display.tput.cursor_shape @cursor.shape, @cursor.blink
      end

      # Resets cursor
      def cursor_reset
        @cursor.shape = Tput::CursorShape::Block
        @cursor.blink = false
        @cursor.style.bg = "#ffffff"
        @cursor._set = false
        display.tput.cursor_reset
      end

      # Sets cursor color
      def cursor_color(color : Tput::Color? = nil)
        # @cursor.style.bg = color.try do |c|
        #  Tput::Color.new Colors.convert(c.value)
        # end
        # @cursor._set = true

        if @cursor.artificial?
          return true
        end

        # display.tput.cursor_color(@cursor.color.to_s.downcase)
        display.tput.cursor_color @cursor.style.bg
      end

      alias_previous reset_cursor

      # :nodoc:
      def _artificial_cursor_attr(cursor, dattr = nil)
        attr = dattr || @dattr
        # cattr
        # ch
        if cursor.shape.line?
          attr &= ~(0x1ff << 9)
          attr |= 7 << 9
          ch = '\u2502'
        elsif cursor.shape.underline?
          attr &= ~(0x1ff << 9)
          attr |= 7 << 9
          attr |= 2 << 18
        elsif cursor.shape.block?
          attr &= ~(0x1ff << 9)
          attr |= 7 << 9
          attr |= 8 << 18
        elsif cursor.shape.none?
          cattr = Widget.sattr cursor.style
          # cattr = Colors.blend attr, cursor.style, (cursor.style.transparency || 0)
          if cursor.style.bold || cursor.style.underline || cursor.style.blink || cursor.style.inverse || cursor.style.invisible
            attr &= ~(0x1ff << 18)
            attr |= ((cattr >> 18) & 0x1ff) << 18
          end
          if cursor.style.fg
            attr &= ~(0x1ff << 9)
            attr |= ((cattr >> 9) & 0x1ff) << 9
          end
          if cursor.style.bg
            attr &= ~(0x1ff << 0)
            attr |= cattr & 0x1ff
          end
          if cursor.style.char
            ch = cursor.style.char
          end
        end

        # TODO is never nil
        unless cursor.style.bg.nil?
          attr &= ~(0x1ff << 9)
          attr |= Colors.convert(cursor.style.bg) << 9
        end

        # Cell.new attr: attr, char: ch || ' '
        {attr, ch || ' '}
      end

      # Shows cursor
      def show_cursor
        if @cursor.artificial?
          @cursor._hidden = false
          render if @renders > 0
        else
          display.tput.show_cursor
        end
      end

      # Hides cursor
      def hide_cursor
        if @cursor.artificial?
          @cursor._hidden = true
          render if @renders > 0
        else
          display.tput.hide_cursor
        end
      end

      # if (!@_cursorBlink)
      # @_cursorBlink = setInterval(function()
      #   if (!self.cursor.blink) return
      #   self.cursor._state ^= 1
      #   if (self.renders) self.render()
      # }, 500)
      # if (@_cursorBlink.unref)
      #   @_cursorBlink.unref()
      # end
      # end
      def cursor_reset
        if @cursor.artificial?
          @cursor.artificial = false
        end

        display.tput.cursor_reset
      end
    end
  end
end
