module Crysterm
  class Window
    # Terminal (not mouse) cursor
    # module Cursor
    include Macros

    # The screen's default cursor. It is used whenever the focused widget does
    # not define its own (see `#active_cursor`). The `Cursor` type now lives at
    # the namespace level (`Crysterm::Cursor`) so that a `Widget` can own one too.
    getter cursor = Cursor.new

    # The cursor currently in effect: the focused widget's own cursor if it has
    # one, otherwise the screen's default `#cursor`.
    #
    # This is the single place that implements "per-widget cursor, falling back
    # to the screen default". Everything that *draws* the cursor (`Window#draw`)
    # or *applies* it to the terminal goes through here, so a focused widget's
    # override transparently wins while everything else keeps using the default.
    # Re-render, but only once the screen has painted at least one frame
    # (`@renders > 0`). The artificial cursor is composited into the cell buffer
    # by `#draw`, so cursor-state changes must repaint to take effect — but only
    # after the first real render, never before (which would paint prematurely).
    # Centralizes the `render if @renders > 0` guard repeated across the cursor
    # and focus code.
    def render_if_active : Nil
      render if @renders > 0
    end

    def active_cursor : Cursor
      focused.try(&.cursor) || @cursor
    end

    # The hardware-cursor primitives — the capability probes
    # (`hardware_cursor_styling?`/`hardware_cursor_color?`) and the raw `tput`
    # shape/color/show-hide/reset operations — now live on the device (`Screen`,
    # in `screen_cursor.cr`); this surface delegates them (see `window.cr`) and
    # calls them below to drive the hardware path.

    # Applies cursor `c`'s settings to the screen. Defaults to the
    # `#active_cursor`, i.e. the focused widget's cursor or the screen default.
    #
    # This is the single place where the hardware-vs-artificial decision is
    # made, so that both paths honor exactly the same cursor state:
    #
    # * A custom (`None`) shape has no hardware equivalent, and any non-default
    #   shape/blink on a terminal that can't style its hardware cursor, is drawn
    #   by Crysterm itself (the artificial cursor).
    # * Otherwise the request is pushed to the terminal's hardware cursor.
    def apply_cursor(c : Cursor = active_cursor)
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
        # The artificial cursor is painted into the buffer by `Window#draw`; a
        # re-render reflects the new settings.
        render_if_active
      else
        c.shape.try { |shape| set_hardware_cursor_shape shape, c.blink }
        # XXX consider a simpler structure than Style for cursor color?
        # The native color is an int (skipping `-1`, the terminal default); the
        # device formats it back to `#rrggbb` for `Tput#cursor_color`.
        c.style.fg.try { |color| set_hardware_cursor_color color if color >= 0 }
      end

      c._set = true
    end

    # Whether the cursor asks for more than the terminal's default (steady
    # block) hardware cursor — i.e. a different shape or blinking.
    private def wants_cursor_styling?(c)
      (c.shape != Tput::CursorShape::Block) || c.blink
    end

    # Sets cursor shape (and blink) on cursor `c` (the screen default by
    # default; a `Widget` passes its own). Works identically for the hardware
    # and the artificial cursor: it records the request and then re-applies the
    # `#active_cursor`, which renders it or emits the hardware escape as
    # appropriate. (When `c` is the focused widget's cursor it *is* the active
    # one, so the change shows immediately; otherwise it is recorded and applied
    # once that cursor becomes active, i.e. on focus.)
    def cursor_shape(shape : Tput::CursorShape = Tput::CursorShape::Block, blink : Bool = false, c : Cursor = @cursor)
      c.shape = shape
      c.blink = blink
      c._set = false
      apply_cursor active_cursor
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

    # Sets cursor color on cursor `c` (the screen default by default; a `Widget`
    # passes its own).
    #
    # The cursor's color is stored as `c.style.fg` (the same field the
    # artificial renderer and `apply_cursor` read), so a single concept drives
    # both the artificial and hardware cursors -- the equivalent of blessed's
    # `cursor.color`. For an artificial cursor this just records the color and
    # the next `render` applies it; otherwise it is pushed to the terminal.
    def cursor_color(color : Int | String | Nil = nil, c : Cursor = @cursor)
      c.style.fg = color
      c._set = true

      ac = active_cursor
      if ac.artificial?
        render_if_active
        return true
      end

      if (x = ac.style.fg) && x >= 0
        set_hardware_cursor_color x
      else
        # Clearing the color (`cursor_color nil`, or a `-1` "terminal default"
        # sentinel): restore the terminal's own hardware cursor color via OSC 112.
        # Previously the `try`-guarded form emitted nothing in this case, so
        # `cursor_color nil` after a prior `cursor_color "red"` was a silent
        # no-op — the hardware cursor stayed stuck at the last color, with no way
        # to put it back to default. Mirrors the artificial path, which drops the
        # override and re-renders to the same end state.
        reset_hardware_cursor_color
      end
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
        # A reverse-video block is the classic terminal cursor: it reads on any
        # background with no color assumption, so keep the cell's own fg/bg and
        # just invert (rather than forcing a white foreground).
        attr = Attr.pack(Attr.flags(attr) | Attr::REVERSE, Attr.fg(attr), Attr.bg(attr))
      elsif cursor.shape.none?
        # `None` is the custom cursor: draw it from the cursor's own `style`
        # (glyph and colors), the equivalent of blessed's object-shaped cursor
        # (`lib/widgets/screen.js`, the `typeof cursor.shape === 'object'` branch).
        cattr = Widget.sattr cursor.style
        # cattr = Colors.blend attr, cursor.style, (cursor.style.alpha || 0)
        flags = Attr.flags(attr)
        if cursor.style.bold? || cursor.style.underline? || cursor.style.blink? || cursor.style.reverse? || !cursor.style.visible?
          flags = Attr.flags(cattr)
        end
        fg = cursor.style.fg ? Attr.fg(cattr) : Attr.fg(attr)
        bg = cursor.style.bg ? Attr.bg(cattr) : Attr.bg(attr)
        attr = Attr.pack(flags, fg, bg)
        if cursor.style.fill_char
          ch = cursor.style.fill_char
        end
      end

      # The white forced above is only a default for the predefined shapes; an
      # explicit `style.fg` recolors the cursor glyph (the equivalent of
      # blessed's `cursor.color`, applied to the FOREGROUND for every shape).
      # `style.bg` additionally tints the BACKGROUND (a Crysterm extension).
      fg = (f = cursor.style.fg) ? Attr.pack_color(f) : Attr.fg(attr)
      bg = (b = cursor.style.bg) ? Attr.pack_color(b) : Attr.bg(attr)
      attr = Attr.pack(Attr.flags(attr), fg, bg)

      # Cell.new attr: attr, char: ch || ' '
      {attr, ch}
    end

    # Shared show/hide path: *hidden* `false` shows, `true` hides. For an
    # artificial cursor this flips its hidden flag and repaints (the buffer-drawn
    # cursor appears/disappears on the next frame); for the hardware cursor it
    # emits the matching tput escape.
    private def set_cursor_hidden(c : Cursor, hidden : Bool) : Nil
      if c.artificial?
        c._hidden = hidden
        render_if_active
      else
        hidden ? hide_hardware_cursor : show_hardware_cursor
      end
    end

    # Shows cursor `c` (the active cursor by default).
    def show_cursor(c : Cursor = active_cursor)
      set_cursor_hidden c, false
    end

    # Hides cursor `c` (the active cursor by default).
    def hide_cursor(c : Cursor = active_cursor)
      set_cursor_hidden c, true
    end

    # Re-enables and resets the hardware cursor. If an artificial cursor was in
    # use, it is turned off and erased (via a re-render) so control returns to
    # the terminal's own cursor. Resets cursor `c` (the screen default by
    # default; a `Widget` resets its own override via `Widget#reset_cursor`).
    def cursor_reset(c : Cursor = @cursor)
      was_artificial = c.artificial?
      c.artificial = false

      c.shape = :block
      c.blink = false
      # No forced color: the artificial block cursor is reverse-video of the cell
      # (see `#_artificial_cursor_attr`), so its style needs no hardcoded bg.
      c.style.bg = nil
      c._set = false

      reset_hardware_cursor

      # Repaint so the previously-drawn artificial cursor cell is cleared.
      render_if_active if was_artificial
    end
    # end
  end
end
