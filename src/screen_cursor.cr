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

    # Whether the terminal can style its *hardware* cursor (shape/blink, via
    # DECSCUSR or iTerm2's OSC 50). Backed by `Tput::Features#cursor_style?`,
    # which is detected statically and can be confirmed at runtime by
    # `Tput#probe!`. When this is false, `apply_cursor` falls back to drawing an
    # artificial cursor for any non-default shape.
    def hardware_cursor_styling?
      !!tput.features?.try(&.cursor_style?)
    end

    # Whether the terminal can recolor its *hardware* cursor (OSC 12). Backed by
    # `Tput::Features#cursor_color?`.
    def hardware_cursor_color?
      !!tput.features?.try(&.cursor_color?)
    end

    # Applies the current cursor settings in `@cursor` to the screen.
    #
    # This is the single place where the hardware-vs-artificial decision is
    # made, so that both paths honor exactly the same `@cursor` state:
    #
    # * A custom (`None`) shape has no hardware equivalent, and any non-default
    #   shape/blink on a terminal that can't style its hardware cursor, is drawn
    #   by Crysterm itself (the artificial cursor).
    # * Otherwise the request is pushed to the terminal's hardware cursor.
    def apply_cursor
      c = @cursor

      # Decide whether the hardware cursor can satisfy the request; if not, draw
      # it ourselves so the requested shape/blink/color is still honored.
      unless c.artificial?
        if c.shape.none?
          c.artificial = true
        elsif wants_cursor_styling?(c) && !hardware_cursor_styling?
          c.artificial = true
        end
      end

      if c.artificial?
        # The artificial cursor is painted into the buffer by `Screen#draw`; a
        # re-render reflects the new settings.
        render if @renders > 0
      else
        c.shape.try { |shape| tput.cursor_shape shape, c.blink }
        # XXX consider a simpler structure than Style for cursor color?
        # XXX Blessed calls this:
        # c.style.fg.try { |color| tput.cursor_color Colors.convert color }
        # Why in our case that produces the following error when it's used:
        # Error: expected argument #1 to 'Tput#cursor_color' to be String or Tput::Namespace::Color, not Int32
        c.style.fg.try { |color| tput.cursor_color color }
      end

      c._set = true
    end

    # Whether the cursor asks for more than the terminal's default (steady
    # block) hardware cursor — i.e. a different shape or blinking.
    private def wants_cursor_styling?(c)
      (c.shape != Tput::CursorShape::Block) || c.blink
    end

    # Sets cursor shape (and blink). Works identically for the hardware and the
    # artificial cursor: it records the request and routes it through
    # `apply_cursor`, which renders it or emits the hardware escape as
    # appropriate.
    def cursor_shape(shape : Tput::CursorShape = Tput::CursorShape::Block, blink : Bool = false)
      @cursor.shape = shape
      @cursor.blink = blink
      @cursor._set = false
      apply_cursor
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

    # Sets cursor color.
    #
    # The cursor's color is stored as `@cursor.style.fg` (the same field the
    # artificial renderer and `apply_cursor` read), so a single concept drives
    # both the artificial and hardware cursors -- the equivalent of blessed's
    # `cursor.color`. For an artificial cursor this just records the color and
    # the next `render` applies it; otherwise it is pushed to the terminal.
    def cursor_color(color : String? = nil)
      @cursor.style.fg = color
      @cursor._set = true

      if @cursor.artificial?
        render if @renders > 0
        return true
      end

      @cursor.style.fg.try { |c| tput.cursor_color c }
    end

    alias_previous reset_cursor

    # :nodoc:
    def _artificial_cursor_attr(cursor, attr : Int64 = @default_attr)
      ch = nil
      # A white-ish foreground keeps the synthetic cursor glyph visible
      # (palette index 7, mapped to its native RGB).
      white = Attr.pack_color(Colors.palette_to_rgb(7))

      if cursor.shape.line?
        attr = Attr.pack(Attr.flags(attr), white, Attr.bg(attr))
        ch = '\u2502'
      elsif cursor.shape.underline?
        attr = Attr.pack(Attr.flags(attr) | Attr::UNDERLINE, white, Attr.bg(attr))
      elsif cursor.shape.block?
        attr = Attr.pack(Attr.flags(attr) | Attr::INVERSE, white, Attr.bg(attr))
      elsif cursor.shape.none?
        # `None` is the custom cursor: draw it from the cursor's own `style`
        # (glyph and colors), the equivalent of blessed's object-shaped cursor
        # (`lib/widgets/screen.js`, the `typeof cursor.shape === 'object'` branch).
        cattr = Widget.sattr cursor.style
        # cattr = Colors.blend attr, cursor.style, (cursor.style.alpha || 0)
        flags = Attr.flags(attr)
        if cursor.style.bold? || cursor.style.underline? || cursor.style.blink? || cursor.style.inverse? || !cursor.style.visible?
          flags = Attr.flags(cattr)
        end
        fg = cursor.style.fg ? Attr.fg(cattr) : Attr.fg(attr)
        bg = cursor.style.bg ? Attr.bg(cattr) : Attr.bg(attr)
        attr = Attr.pack(flags, fg, bg)
        if cursor.style.char
          ch = cursor.style.char
        end
      end

      # The white forced above is only a default for the predefined shapes; an
      # explicit `style.fg` recolors the cursor glyph (the equivalent of
      # blessed's `cursor.color`, applied to the FOREGROUND for every shape).
      # `style.bg` additionally tints the BACKGROUND (a Crysterm extension).
      if f = cursor.style.fg
        attr = Attr.pack(Attr.flags(attr), Attr.pack_color(Colors.convert(f)), Attr.bg(attr))
      end
      if b = cursor.style.bg
        attr = Attr.pack(Attr.flags(attr), Attr.fg(attr), Attr.pack_color(Colors.convert(b)))
      end

      # Cell.new attr: attr, char: ch || ' '
      {attr, ch}
    end

    # Shows cursor
    def show_cursor
      if @cursor.artificial?
        @cursor._hidden = false
        render if @renders > 0
      else
        tput.show_cursor
      end
    end

    # Hides cursor
    def hide_cursor
      if @cursor.artificial?
        @cursor._hidden = true
        render if @renders > 0
      else
        tput.hide_cursor
      end
    end

    # Re-enables and resets the hardware cursor. If an artificial cursor was in
    # use, it is turned off and erased (via a re-render) so control returns to
    # the terminal's own cursor.
    def cursor_reset
      was_artificial = @cursor.artificial?
      @cursor.artificial = false

      @cursor.shape = Tput::CursorShape::Block
      @cursor.blink = false
      @cursor.style.bg = "#ffffff"
      @cursor._set = false

      tput.cursor_reset

      # Repaint so the previously-drawn artificial cursor cell is cleared.
      render if was_artificial && @renders > 0
    end
    # end
  end
end
