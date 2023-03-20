module Crysterm
  class Screen
    # Terminal (not mouse) cursor
    # module Cursor
    include Macros

    # TODO - temporary until @cursor is moved to widget. This is extended because
    # Tput class does not have a property for color.
    class Cursor < Tput::Namespace::Cursor
      property style : Style = Style.new(char: '▮')
    end

    getter cursor = Cursor.new

    # Should all these functions go to tput?

    # Applies current cursor settings in `@cursor` to screen/display
    def apply_cursor
      c = @cursor
      # XXX Maybe checking for artificial makes sense here, but in blessed
      # it's not done.
      # if c.artificial?
      #  render
      # else
      display.try do |d|
        c.shape.try { |shape| d.tput.cursor_shape shape, c.blink }
        # XXX consider a simpler structure than Style for cursor color?
        # XXX Blessed calls this:
        # c.style.fg.try { |color| d.tput.cursor_color Colors.convert color }
        # Why in our case that produces the following error when it's used:
        # Error: expected argument #1 to 'Tput#cursor_color' to be String or Tput::Namespace::Color, not Int32
        c.style.fg.try { |color| d.tput.cursor_color color }
      end
      # end
      c._set = true
    end

    # Sets cursor shape
    def cursor_shape(shape : Tput::CursorShape = Tput::CursorShape::Block, blink : Bool = false)
      @cursor.shape = shape
      @cursor.blink = blink
      @cursor._set = true
      display.tput.cursor_shape @cursor.shape, @cursor.blink
    end

    # XXX where does this belong?
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
      display.tput.cursor_color @cursor.style.fg
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
        # cattr = Colors.blend attr, cursor.style, (cursor.style.alpha || 0)
        if cursor.style.bold || cursor.style.underline || cursor.style.blink || cursor.style.inverse || !cursor.style.visible
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

    # Re-enables and resets hardware cursor
    def cursor_reset
      if @cursor.artificial?
        @cursor.artificial = false
      end

      display.tput.cursor_reset
    end
    # end
  end
end
