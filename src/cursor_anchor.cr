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
  # (`Tput#report_cursor`, `\e[6n`).
  #
  # NOTE: `report_cursor` reads `@input` synchronously and must not race the input
  # listen loop — sample it *before* the loop starts. Falls back to *fallback*
  # when the terminal doesn't answer (non-tty / headless).
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
  # widget's *painted* content origin (the rendered `lpos` row — which inside a
  # scrolled/clipped container differs from layout `atop` by the enclosing
  # scroll base — plus `itop`; columns via `aleft + ileft`, which matches the
  # painted origin because horizontal clipping carries no base) plus the
  # emulator's cursor cell. This mirrors `Terminal#draw`'s cursor painting and
  # `Terminal#on_mouse`'s row mapping, so a popup at `relative(1, 0)` of this
  # anchor lands one row below the shell's *visible* cursor, inside the
  # terminal widget.
  #
  # Falls back to the layout origin (`atop + itop`) before the first render,
  # and to the content origin when the terminal has no live emulator yet.
  class WidgetCursorAnchor < CursorAnchor
    def initialize(@terminal : Widget::Terminal)
    end

    def cursor_pos : {Int32, Int32}
      t = @terminal
      col = t.aleft + t.ileft
      # Map through the painted rect, exactly as `Terminal#draw` paints the
      # cursor (`coords.yi + itop + cursor_y - coords.base`): inside a scrolled
      # container `lpos.yi != atop`, and when the terminal's own top rows are
      # clipped the emulator row at `yi` is `base`, not 0.
      row =
        if lp = t.last_rendered_position?
          lp.yi + t.itop - lp.base
        else
          t.atop + t.itop
        end
      if em = t.emulator
        {row + em.cursor_y, col + em.cursor_x}
      else
        {row, col}
      end
    end
  end
end
