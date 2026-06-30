module Crysterm
  # Device-side hardware-cursor control — the half of cursor handling that drives
  # the REAL terminal cursor through `tput` (shape/blink, color, show/hide, full
  # reset), plus the static capability probes for what the hardware cursor can
  # do. These are pure `tput`/IO concerns, so they live on the physical device
  # (`Screen`).
  #
  # The *artificial* cursor (composited into the cell buffer by `Window#draw`)
  # and the hardware-vs-artificial decision read surface state (the focused
  # widget's cursor, the cell buffer, rendering), so they stay on `Window`
  # (`window_cursor.cr`). Those surface-coordination methods drive the hardware
  # path by calling the primitives here (delegated from `Window`).
  class Screen
    # Whether the terminal can style its *hardware* cursor (shape/blink, via
    # DECSCUSR or iTerm2's OSC 50). Backed by `Tput::Features#cursor_style?`,
    # which is detected statically and can be confirmed at runtime by
    # `Tput#probe!`. When this is false, `Window#apply_cursor` falls back to
    # drawing an artificial cursor for any non-default shape.
    def hardware_cursor_styling?
      !!tput.features?.try(&.cursor_style?)
    end

    # Whether the terminal can recolor its *hardware* cursor (OSC 12). Backed by
    # `Tput::Features#cursor_color?`.
    def hardware_cursor_color?
      !!tput.features?.try(&.cursor_color?)
    end

    # Pushes *shape* (and *blink*) to the terminal's hardware cursor (DECSCUSR).
    def set_hardware_cursor_shape(shape : ::Tput::CursorShape, blink : Bool) : Nil
      tput.cursor_shape shape, blink
    end

    # Recolors the hardware cursor (OSC 12). *color* is a native `0xRRGGBB` int;
    # `Tput#cursor_color` wants a `String`, so format it back to `#rrggbb`.
    def set_hardware_cursor_color(color : Int32) : Nil
      tput.cursor_color "#%06x" % color
    end

    # Restores the terminal's own hardware cursor color (OSC 112).
    def reset_hardware_cursor_color : Nil
      tput.reset_cursor_color
    end

    # Shows the hardware cursor.
    def show_hardware_cursor : Nil
      tput.show_cursor
    end

    # Hides the hardware cursor.
    def hide_hardware_cursor : Nil
      tput.hide_cursor
    end

    # Re-enables and resets the hardware cursor to the terminal default.
    def reset_hardware_cursor : Nil
      tput.cursor_reset
    end
  end
end
