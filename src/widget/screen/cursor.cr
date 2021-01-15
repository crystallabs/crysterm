module Crysterm
  class Screen < Node
    module Cursor
      include Macros
      getter cursor = Tput::Namespace::Cursor.new

      def cursor_shape(shape : CursorShape = CursorShape::Block, blink : Bool = false)
        @cursor.shape = shape
        @cursor.blink = blink
        @cursor._set = true

        if @cursor.artificial
          raise "Not supported yet"
          # if !application.hide_cursor_old
          #  hide_cursor = application.hide_cursor
          #  application.tput.hide_cursor_old = application.hide_cursor
          #  application.tput.hide_cursor = ->{
          #    hide_cursor.call(application)
          #    @cursor._hidden = true
          #    if (@renders > 0)
          #      render
          #    end
          #  }
          # end
          # if (!application.showCursor_old)
          #  var showCursor = application.showCursor
          #  application.showCursor_old = application.showCursor
          #  application.showCursor = function()
          #    self.cursor._hidden = false
          #    if (application._exiting) showCursor.call(application)
          #    if (self.renders) self.render()
          #  }
          # end
          # if (!@_cursorBlink)
          #  @_cursorBlink = setInterval(function()
          #    if (!self.cursor.blink) return
          #    self.cursor._state ^= 1
          #    if (self.renders) self.render()
          #  }, 500)
          #  if (@_cursorBlink.unref)
          #    @_cursorBlink.unref()
          #  end
          # end
          return true
        end

        application.tput.cursor_shape @cursor.shape, @cursor.blink
      end

      def cursor_color(color : Tput::Color? = nil)
        @cursor.color = color.try do |c|
          Tput::Color.new Colors.convert(c.value)
        end
        @cursor._set = true

        if (@cursor.artificial)
          return true
        end

        # TODO probably this isn't fully right
        application.tput.cursor_color(@cursor.color.to_s.downcase)
      end

      def cursor_reset
        @cursor = Tput::Namespace::Cursor.new
        # TODO if artificial cursor

        application.tput.cursor_reset
      end

      alias_previous reset_cursor

      def _cursor_attr(cursor, dattr = nil)
        attr = dattr || @dattr
        # cattr
        # ch
        if (cursor.shape == CursorShape::Line)
          attr &= ~(0x1ff << 9)
          attr |= 7 << 9
          ch = '\u2502'
        elsif (cursor.shape == CursorShape::Underline)
          attr &= ~(0x1ff << 9)
          attr |= 7 << 9
          attr |= 2 << 18
        elsif (cursor.shape == CursorShape::Block)
          attr &= ~(0x1ff << 9)
          attr |= 7 << 9
          attr |= 8 << 18
        elsif (cursor.shape)
          # TODO
          # cattr = Element.sattr(cursor, cursor.shape)
          # if (cursor.shape.bold || cursor.shape.underline ||
          #    cursor.shape.blink || cursor.shape.inverse ||
          #    cursor.shape.invisible)
          #  attr &= ~(0x1ff << 18)
          #  attr |= ((cattr >> 18) & 0x1ff) << 18
          # end
          # if (cursor.shape.fg)
          #  attr &= ~(0x1ff << 9)
          #  attr |= ((cattr >> 9) & 0x1ff) << 9
          # end
          # if (cursor.shape.bg)
          #  attr &= ~(0x1ff << 0)
          #  attr |= cattr & 0x1ff
          # end
          # if (cursor.shape.ch)
          #  ch = cursor.shape.ch
          # end
        end

        unless (cursor.color.nil?)
          attr &= ~(0x1ff << 9)
          attr |= cursor.color.value << 9
        end

        return Cell.new \
          attr: attr,
          char: ch || ' '
      end

      def _reduce_color(col)
        Colors.reduce(col, application.tput.features.number_of_colors)
      end
    end
  end
end
