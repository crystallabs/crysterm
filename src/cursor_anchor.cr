module Crysterm
  # Locates the text cursor within some *host* coordinate space and computes
  # placement relative to it. This is the unifying primitive behind "anchored" /
  # inline rendering: a completer, popup, or region anchored *at the cursor*
  # works the same way whether the host is the real terminal or an embedded
  # `Widget::Terminal` — only the source of the cursor cell differs.
  #
  # All coordinates are 0-based cells in the host's own space:
  # - `TerminalCursorAnchor` — the real terminal; cursor from a DSR query.
  # - `WidgetCursorAnchor` — an embedded `Widget::Terminal`; cursor from its
  #   emulator, translated into the owning `Window`'s coordinate space.
  #
  # The two consumers:
  # - an inline (`alternate: false`) `Window` anchors its whole surface at
  #   `cursor_row` (`Window#render_row_offset`);
  # - a completer/popup anchors a child widget at `relative(...)` of the cursor.
  abstract class CursorAnchor
    # The cursor's current cell `{row, col}` in the host coordinate space.
    abstract def cursor_pos : {Int32, Int32}

    # Row of the cursor in the host coordinate space.
    def cursor_row : Int32
      cursor_pos[0]
    end

    # Column of the cursor in the host coordinate space.
    def cursor_col : Int32
      cursor_pos[1]
    end

    # Absolute host coordinates `{row, col}` for a cell offset *(dy, dx)* from
    # the cursor. `relative(-2, -2)` is two rows up and two columns left of the
    # cursor; `relative(1, 0)` is the line directly below it (where a drop-down
    # completer sits). Pure placement math — it does not move the cursor.
    def relative(dy : Int32, dx : Int32) : {Int32, Int32}
      r, c = cursor_pos
      {r + dy, c + dx}
    end
  end

  # Anchors to the **real terminal's** hardware cursor, queried once via DSR
  # (`Tput#report_cursor`, `\e[6n`). Used by an inline `Window` to learn the row
  # to anchor its region at.
  #
  # NOTE: `report_cursor` reads `@input` synchronously and must not race the
  # input listen loop — sample it *before* the loop starts (see
  # `Window#capture_inline_anchor`). Falls back to *fallback* when the terminal
  # doesn't answer (non-tty / headless).
  class TerminalCursorAnchor < CursorAnchor
    def initialize(@screen : Screen, @fallback : {Int32, Int32} = {0, 0})
    end

    def cursor_pos : {Int32, Int32}
      if p = @screen.tput.report_cursor
        {p.y, p.x}
      else
        @fallback
      end
    end
  end

  # Anchors to the cursor of an embedded `Widget::Terminal`'s emulator,
  # translated into the owning `Window`'s coordinate space: the terminal
  # widget's on-screen content origin (`atop + itop`, `aleft + ileft`) plus the
  # emulator's cursor cell. A popup placed at `relative(1, 0)` of this anchor
  # therefore lands one row below the shell's cursor, *inside* the terminal
  # widget — and because that popup is an ordinary widget in the same Window
  # tree, it gets mouse hover/selection/scrolling for free.
  #
  # Falls back to the content origin when the terminal has no live emulator yet.
  class WidgetCursorAnchor < CursorAnchor
    def initialize(@terminal : Widget::Terminal)
    end

    def cursor_pos : {Int32, Int32}
      t = @terminal
      row = t.atop + t.itop
      col = t.aleft + t.ileft
      if em = t.emulator
        {row + em.cursor_y, col + em.cursor_x}
      else
        {row, col}
      end
    end
  end
end
