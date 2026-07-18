module Crysterm
  class Window
    # Terminal (not mouse) cursor
    include Macros

    # The screen's default cursor, used whenever the focused widget defines no
    # own. `Cursor` lives at namespace level (`Crysterm::Cursor`) so a `Widget`
    # can own one too.
    getter cursor = Cursor.new

    # Re-renders only once the screen has painted at least one frame, since the
    # artificial cursor is composited into the cell buffer by `#draw` and
    # cursor-state changes must repaint to take effect.
    private def render_if_active : Nil
      render if @renders > 0
    end

    # The cursor in effect: the focused widget's own cursor, else the screen
    # default `#cursor`.
    def active_cursor : Cursor
      focused.try(&.cursor) || @cursor
    end

    # The hardware-cursor primitives (capability probes and the raw `tput`
    # shape/color/show-hide/reset ops) live on the device (`Screen`); this
    # surface delegates them.

    # Applies cursor `c`'s settings to the screen (defaults to `#active_cursor`).
    # Makes the hardware-vs-artificial decision:
    #
    # * A custom (`None`) shape, or any non-default shape/blink on a terminal
    #   that can't style its hardware cursor, is drawn by Crysterm (artificial).
    # * Otherwise the request is pushed to the hardware cursor.
    def apply_cursor(c : Cursor = active_cursor)
      # If the hardware cursor can't satisfy the request, draw it ourselves.
      # Re-derived unconditionally every call: gating on the current
      # `c.artificial?` would make the decision monotonic, so a cursor once
      # turned artificial could never go back to hardware.
      c.artificial = c.shape.none? || (wants_cursor_styling?(c) && !hardware_cursor_styling?)

      if c.artificial?
        # Artificial cursor is painted by `Window#draw`; re-render to reflect.
        render_if_active
      else
        c.shape.try { |shape| apply_hardware_cursor_shape shape, blink: c.blink }
        # XXX consider a simpler structure than Style for cursor color?
        # Native color is an int (`-1` = terminal default); device formats it
        # to `#rrggbb` for `Tput#cursor_color`.
        push_hardware_cursor_color c
      end

      c._set = true
    end

    # Whether the cursor asks for more than the default steady block — i.e. a
    # different shape or blinking.
    private def wants_cursor_styling?(c)
      (c.shape != Tput::CursorShape::Block) || c.blink
    end

    # Pushes cursor `c`'s color to the hardware cursor: sets it when `c.style.fg`
    # is a real color (`>= 0`), else restores the terminal's own hardware cursor
    # color via OSC 112 (else a stale color from a previously-focused cursor
    # persists).
    private def push_hardware_cursor_color(c : Cursor) : Nil
      if (color = c.style.fg) && color >= 0
        self.hardware_cursor_color = color
      else
        reset_hardware_cursor_color
      end
    end

    # Sets cursor shape (and blink) on *cursor* (the screen default by default;
    # a `Widget` passes its own via `Widget#set_cursor`). If *cursor* isn't the
    # active cursor, the change shows once it becomes active (on focus).
    def set_cursor_shape(shape : Tput::CursorShape, *, blink : Bool = false, cursor : Cursor = @cursor) : Nil
      cursor.shape = shape
      cursor.blink = blink
      cursor._set = false
      apply_cursor active_cursor
    end

    # Sets the screen's own default cursor shape, leaving blink unchanged. See
    # `#set_cursor_shape` to set both, or to target a specific cursor.
    def cursor_shape=(shape : Tput::CursorShape) : Tput::CursorShape
      set_cursor_shape shape, blink: @cursor.blink
      shape
    end

    # Sets cursor color on *cursor* (the screen default by default; a `Widget`
    # passes its own via `Widget#cursor_color=`).
    #
    # Color is stored as `cursor.style.fg`, the one field driving both the
    # artificial renderer and `#apply_cursor`. An artificial cursor applies it
    # on the next `render`; otherwise it is pushed to the terminal.
    def set_cursor_color(color : Int | String | Nil, cursor : Cursor = @cursor) : Nil
      cursor.style.fg = color
      cursor._set = true

      ac = active_cursor
      if ac.artificial?
        render_if_active
        return
      end

      push_hardware_cursor_color ac
    end

    # Sets the screen's own default cursor color. See `#set_cursor_color` to
    # target a specific cursor.
    def cursor_color=(color : Int | String | Nil) : Nil
      set_cursor_color color
    end

    # :nodoc:
    def _artificial_cursor_attr(cursor, attr : Int64 = @default_attr)
      ch = nil
      # White-ish foreground keeps the synthetic cursor glyph visible
      # (palette index 7, mapped to native RGB).
      white = Attr.pack_color(Colors.palette_to_rgb(7))

      if cursor.shape.line?
        attr = Attr.pack(Attr.flags(attr), white, Attr.bg(attr))
        ch = Glyphs[Glyphs::Role::CursorBar, glyph_tier]
      elsif cursor.shape.underline?
        attr = Attr.pack(Attr.flags(attr) | Attr::UNDERLINE, white, Attr.bg(attr))
      elsif cursor.shape.block?
        # Reverse-video block, the classic terminal cursor: reads on any
        # background, so keep the cell's own fg/bg and invert.
        attr = Attr.pack(Attr.flags(attr) | Attr::REVERSE, Attr.fg(attr), Attr.bg(attr))
      elsif cursor.shape.none?
        # `None` is the custom cursor: draw it from the cursor's own `style` (glyph and colors).
        cattr = Widget.style_to_attr cursor.style
        flags = Attr.flags(attr)
        if cursor.style.bold? || cursor.style.underline? || cursor.style.blink? || cursor.style.reverse? || cursor.style.italic? || cursor.style.strike? || !cursor.style.visible?
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
    def reset_cursor(c : Cursor = @cursor)
      was_artificial = c.artificial?
      c.artificial = false

      c.shape = :block
      c.blink = false
      # No forced color: the artificial block cursor is reverse-video of the
      # cell, so needs no hardcoded fg/bg. `style.fg` is the single source of
      # truth `#apply_cursor` reads, so leaving it set would let a later
      # re-apply re-issue the old color — the OSC-112 reset here holds only
      # until then.
      c.style.fg = nil
      c.style.bg = nil
      c._set = false

      reset_hardware_cursor

      # Repaint to clear the previously-drawn artificial cursor cell.
      render_if_active if was_artificial
    end
  end
end
