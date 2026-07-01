module Crysterm
  class Window
    # Terminal (not mouse) cursor
    # module Cursor
    include Macros

    # The screen's default cursor, used whenever the focused widget defines no
    # own (see `#active_cursor`). `Cursor` lives at namespace level
    # (`Crysterm::Cursor`) so a `Widget` can own one too.
    getter cursor = Cursor.new

    # The cursor in effect: the focused widget's own cursor, else the screen
    # default `#cursor`. Everything that draws (`Window#draw`) or applies it
    # goes through here.
    #
    # Re-renders only once the screen has painted at least one frame
    # (`@renders > 0`), since the artificial cursor is composited into the cell
    # buffer by `#draw` and cursor-state changes must repaint to take effect.
    # Centralizes the `render if @renders > 0` guard repeated across cursor and
    # focus code.
    def render_if_active : Nil
      render if @renders > 0
    end

    def active_cursor : Cursor
      focused.try(&.cursor) || @cursor
    end

    # The hardware-cursor primitives (capability probes
    # `hardware_cursor_styling?`/`hardware_cursor_color?` and the raw `tput`
    # shape/color/show-hide/reset ops) live on the device (`Screen`,
    # `screen_cursor.cr`); this surface delegates them (see `window.cr`).

    # Applies cursor `c`'s settings to the screen (defaults to `#active_cursor`).
    # Makes the hardware-vs-artificial decision:
    #
    # * A custom (`None`) shape, or any non-default shape/blink on a terminal
    #   that can't style its hardware cursor, is drawn by Crysterm (artificial).
    # * Otherwise the request is pushed to the hardware cursor.
    def apply_cursor(c : Cursor = active_cursor)
      # If the hardware cursor can't satisfy the request, draw it ourselves.
      # Re-derived unconditionally every call: gating on the current
      # `c.artificial?` made the decision monotonic — once a cursor turned
      # artificial (e.g. an underline shape the hardware couldn't style) a later
      # request the hardware *can* render (a steady block) stayed artificial
      # forever, since the `unless` short-circuited the re-evaluation.
      c.artificial = c.shape.none? || (wants_cursor_styling?(c) && !hardware_cursor_styling?)

      if c.artificial?
        # Artificial cursor is painted by `Window#draw`; re-render to reflect.
        render_if_active
      else
        c.shape.try { |shape| set_hardware_cursor_shape shape, c.blink }
        # XXX consider a simpler structure than Style for cursor color?
        # Native color is an int (`-1` = terminal default); device formats it
        # to `#rrggbb` for `Tput#cursor_color`.
        if (color = c.style.fg) && color >= 0
          set_hardware_cursor_color color
        else
          # No color on this cursor (nil / `-1`): restore the terminal's own
          # hardware cursor color via OSC 112, else a stale color from a
          # previously-focused cursor persists. Mirrors `#cursor_color`.
          reset_hardware_cursor_color
        end
      end

      c._set = true
    end

    # Whether the cursor asks for more than the default steady block — i.e. a
    # different shape or blinking.
    private def wants_cursor_styling?(c)
      (c.shape != Tput::CursorShape::Block) || c.blink
    end

    # Sets cursor shape (and blink) on cursor `c` (screen default by default; a
    # `Widget` passes its own). If `c` isn't the active cursor, the change shows
    # once `c` becomes active (on focus).
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

    # Sets cursor color on cursor `c` (screen default by default; a `Widget`
    # passes its own).
    #
    # Color is stored as `c.style.fg` (the field the artificial renderer and
    # `apply_cursor` read), so one concept drives both cursors. Artificial:
    # recorded, applied on next `render`; otherwise pushed to the terminal.
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
        # Clearing the color (`cursor_color nil`, or `-1`): restore the
        # terminal's own hardware cursor color via OSC 112, else `cursor_color
        # nil` after `cursor_color "red"` is a silent no-op.
        reset_hardware_cursor_color
      end
    end

    alias_previous reset_cursor

    # :nodoc:
    def _artificial_cursor_attr(cursor, attr : Int64 = @default_attr)
      ch = nil
      # White-ish foreground keeps the synthetic cursor glyph visible
      # (palette index 7, mapped to native RGB).
      white = Attr.pack_color(Colors.palette_to_rgb(7))

      if cursor.shape.line?
        attr = Attr.pack(Attr.flags(attr), white, Attr.bg(attr))
        ch = '\u2502'
      elsif cursor.shape.underline?
        attr = Attr.pack(Attr.flags(attr) | Attr::UNDERLINE, white, Attr.bg(attr))
      elsif cursor.shape.block?
        # Reverse-video block, the classic terminal cursor: reads on any
        # background, so keep the cell's own fg/bg and invert.
        attr = Attr.pack(Attr.flags(attr) | Attr::REVERSE, Attr.fg(attr), Attr.bg(attr))
      elsif cursor.shape.none?
        # `None` is the custom cursor: draw it from the cursor's own `style` (glyph and colors).
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

      # The forced white is only a default for predefined shapes; an explicit
      # `style.fg` recolors the glyph foreground for every shape. `style.bg`
      # also tints the background (Crysterm extension).
      fg = (f = cursor.style.fg) ? Attr.pack_color(f) : Attr.fg(attr)
      bg = (b = cursor.style.bg) ? Attr.pack_color(b) : Attr.bg(attr)
      attr = Attr.pack(Attr.flags(attr), fg, bg)

      # Cell.new attr: attr, char: ch || ' '
      {attr, ch}
    end

    # Shared show/hide path: *hidden* `false` shows, `true` hides. Artificial:
    # flips its hidden flag and repaints; hardware: emits the matching tput escape.
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

    # Re-enables and resets the hardware cursor; any artificial cursor is
    # turned off and erased (via re-render). Resets cursor `c` (screen default
    # by default; a `Widget` resets its own via `Widget#reset_cursor`).
    def cursor_reset(c : Cursor = @cursor)
      was_artificial = c.artificial?
      c.artificial = false

      c.shape = :block
      c.blink = false
      # No forced color: the artificial block cursor is reverse-video of the cell
      # (see `#_artificial_cursor_attr`), so needs no hardcoded fg/bg. `style.fg`
      # is the single source of truth `#apply_cursor` reads (line ~57), so
      # leaving it set let a later re-apply (on the next focus change or
      # `#cursor_shape`/`#cursor_color`) re-issue the old color — the OSC-112
      # reset done here only held until then.
      c.style.fg = nil
      c.style.bg = nil
      c._set = false

      reset_hardware_cursor

      # Repaint to clear the previously-drawn artificial cursor cell.
      render_if_active if was_artificial
    end
    # end
  end
end
