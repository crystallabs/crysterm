module Crysterm
  class Widget
    abstract class AbstractScrollArea
      # Rulers: a column ruler along the viewport's top row and a row ruler
      # down its leftmost columns, shown with `#rulers = true`. Qt's
      # `QAbstractScrollArea` has none; the margins of QScintilla and the
      # rulers Qt Designer's form editor hangs on its canvas are the nearest
      # kin, and like them the rulers are chrome of the view's own, reserved
      # through `#viewport_margins` (the band the line-number gutter,
      # `#line_numbers=`, sits in; with both shown the gutter is the outer one and the
      # row ruler stands between it and the text), so the text lays out,
      # scrolls and takes the mouse below and right of them.
      #
      # The column ruler counts in the text's own coordinates — column 1 is
      # the text's first column wherever `#line_wrap_column` and its
      # alignment put it, and a horizontal scroll slides the numbers with the
      # text — as a tape of `─` with a `┼` every fifth column and a `│` on
      # every tenth with its number right after it, so the mark itself is on
      # the column named (`│20` marks column 20). The row ruler counts the
      # document's rows the same way, numbering the visible ones from the top
      # of the document, so it tells where the view is where the gutter tells
      # which source line a row came from; it is as wide as the row count's
      # digits (two at least) — or, for a widget whose own margins already
      # number the rows (`#row_ruler_numbers?` false, a view with its
      # gutter on), a one-column tape of ticks: `│` on a
      # row, `┼` on every fifth, `╪` on every tenth. A guide
      # (`#guides_enabled=`) hangs from the column ruler as a `┬`, and is
      # pulled off it with the mouse.
      # `AbstractScrollArea::ruler { color: … }` styles the rulers; with no
      # rule they fade the widget's own foreground toward its background, the
      # way the gutter does. `Event::RulersChanged` follows the toggle, for a
      # View menu entry bound to it. The two are also switched one at a
      # time (`#column_ruler=`, `#row_ruler=`), for a view that wants the
      # column count without a band down its left, or the other way round.
      #
      # Whether either ruler is shown.
      def rulers? : Bool
        @column_ruler || @row_ruler
      end

      # Whether the column ruler is shown; see `#rulers?`.
      getter? column_ruler : Bool = false

      # Whether the row ruler is shown; see `#rulers?`.
      getter? row_ruler : Bool = false

      # Shows or hides both rulers — the band is reserved (or released) at
      # once, so the next frame already lays the text out beside it.
      def rulers=(value : Bool) : Bool
        set_rulers value, value
        value
      end

      # Shows or hides the column ruler alone.
      def column_ruler=(value : Bool) : Bool
        set_rulers value, @row_ruler
        value
      end

      # Shows or hides the row ruler alone.
      def row_ruler=(value : Bool) : Bool
        set_rulers @column_ruler, value
        value
      end

      # The one place the two flags change: the band follows, and
      # `Event::RulersChanged` reports whether any ruler shows, once, when
      # that or the band changed.
      private def set_rulers(column : Bool, row : Bool) : Nil
        return if column == @column_ruler && row == @row_ruler
        was = rulers?
        @column_ruler = column
        @row_ruler = row
        sync_ruler_width
        @_frame_insets = nil
        emit Crysterm::Event::RulersChanged, rulers? if rulers? != was
        update
        update! if window?
      end

      # Fewest digit columns the line-number gutter and the row ruler show,
      # so they don't jitter between 9 and 10 lines on a short document.
      CHROME_MIN_DIGITS = 2

      # How far the gutter's, a ruler's or a guide's foreground fades toward
      # the background when no `::line-number`/`::ruler`/`::guide` rule styles
      # it: the weight of the text color in the mix.
      CHROME_FADE = 0.55

      # Columns the row ruler takes this frame, 0 while `#row_ruler?` is
      # off; the column ruler's row is `#column_ruler?` itself.
      @vertical_ruler_width = 0

      # Whether the row ruler prints the row numbers, or is a one-column
      # tape of ticks beside a gutter that already numbers the lines, is
      # `#row_ruler_numbers?` (`line_numbers.cr`): no while the gutter shows.

      # The row ruler's width, in columns: the row count's digits, so a
      # thousand-row document gets a fourth column (`CHROME_MIN_DIGITS` at
      # least), or one column while `#row_ruler_numbers?` is false.
      # Re-derived before each layout (`#process_content`) from the rows the
      # last one produced — the count can only change with a new layout, and
      # a width that grows by it settles the frame after, as the scroll bar's
      # reservation does.
      private def sync_ruler_width : Nil
        w = if !@row_ruler
              0
            elsif row_ruler_numbers?
              Math.max(decimal_digits(@wrapped_lines.size), CHROME_MIN_DIGITS)
            else
              1
            end
        return if w == @vertical_ruler_width
        @vertical_ruler_width = w
        @_frame_insets = nil
      end

      # Digits of *n* in base 10 (one for 0), without a `String`.
      private def decimal_digits(n : Int32) : Int32
        digits = 1
        while n >= 10
          n //= 10
          digits += 1
        end
        digits
      end

      # The on-window frame the chrome paints and hit-tests in, from the
      # last render: `{x0, xl, y0, yl, text_x0, content_top}` — the band's
      # first column (the subclass's own margin's, the gutter's; the row
      # ruler stands `@viewport_margins.left` columns in from it) and the
      # row the column ruler is on (the padding's inner edge); the text
      # area's exclusive right and bottom edges — `#iright`/`#ibottom` leave
      # out the padding, `@viewport_margins`' right and bottom and a
      # centered column's right slack alike, and of the vertical scroll bar
      # what of it stands in the text area besides (`#scrollbar_overlap`; a
      # bar beside a capped column is in its right inset already) — so the
      # tape ends with the text's rows; the screen column the
      # text's column 1 is at (before the horizontal scroll) and the first
      # content row. The same arithmetic
      # `#position_at` and `#_update_cursor` do, from `#ileft`/`#itop`, so a
      # column the ruler names is the column a click there lands on. nil
      # without a render.
      private def chrome_frame : {Int32, Int32, Int32, Int32, Int32, Int32}?
        lp = @lpos || return
        vm = @viewport_margins
        text_x0 = lp.xi + ileft
        content_top = lp.yi + itop
        x0 = text_x0 - @column_margins[0] - vm.left - @vertical_ruler_width
        y0 = content_top - vm.top - (@column_ruler ? 1 : 0)
        xl = lp.xl - iright - scrollbar_overlap
        yl = lp.yl - ibottom - hscrollbar_rows
        {x0, xl, y0, yl, text_x0, content_top}
      end

      # The text column (1-based, in the text's coordinates, the horizontal
      # scroll counted in) the screen column *x* is on, given the text's
      # origin *text_x0*; 0 is the column just before the text.
      private def text_column_at(x : Int32, text_x0 : Int32) : Int32
        x - text_x0 + 1 + @child_base_x
      end

      # Paints the rulers after the base render: the column ruler on the row
      # above the content, from the row ruler's right edge to the interior's,
      # and the row ruler down the content rows, right of the subclass's own
      # margin (the gutter). The base render filled the band with the
      # widget's background; both are written via `#chrome_attr`. Columns
      # before the text's first (a centered column's left slack) stay blank
      # — the tape starts at the text, so a horizontal scroll slides the
      # numbers under it and not into the slack — and so do rows past the
      # document's end.
      private def paint_rulers : Nil
        lp = @lpos || return
        x0, xl, y0, yl, text_x0, content_top = chrome_frame || return
        return if xl <= x0 || yl <= y0
        rows = window.cell_rows
        attr = chrome_attr(style.ruler?)
        vw = @vertical_ruler_width
        ruler_x0 = x0 + @viewport_margins.left
        if @column_ruler && y0 >= 0 && (row = rows[y0]?)
          (Math.max(tape_x0(x0), text_x0)...xl).each do |x|
            next if x < 0
            cell = row[x]? || break
            cell.set_if_changed attr, column_ruler_glyph(text_column_at(x, text_x0))
          end
        end
        return if vw == 0
        numbers = row_ruler_numbers?
        total = @wrapped_lines.size
        (content_top...yl).each do |y|
          next if y < 0
          row = rows[y]? || break
          r = lp.base + (y - content_top) + 1
          paint_row_ruler_cells row, ruler_x0, vw, (r <= total ? r : 0), numbers, chrome_row_attr(r - 1, attr)
        end
      end

      # The screen column the column ruler's tape starts at, given the band's
      # first column *x0*: past the subclass's own margin (a gutter) and the
      # row ruler — the one place the band's order, gutter then ruler then
      # text, is spelled for the chrome and its hit tests.
      private def tape_x0(x0 : Int32) : Int32
        x0 + @viewport_margins.left + @vertical_ruler_width
      end

      # The column ruler's glyph at text column *col*: a `│` on a tenth
      # column, the digits of the last tenth's number on the columns right
      # after it (`│20` — the mark is on column 20, the digits on 21 and
      # 22), a `┼` on a fifth column, `─` elsewhere, and a blank before
      # column 1.
      private def column_ruler_glyph(col : Int32) : Char
        return ' ' if col <= 0
        return '│' if col % 10 == 0
        tens = col // 10 * 10
        if tens > 0 && (offset = col - tens) <= (digits = decimal_digits(tens))
          '0' + (tens // 10 ** (digits - offset)) % 10
        elsif col % 5 == 0
          '┼'
        else
          '─'
        end
      end

      # Writes the row ruler's *width* cells of *row* at *x0* on for document
      # row *r* (1-based; 0 for a row past the end, left blank): with
      # *numbers*, the number right-aligned on a tenth row, a `┼` in the last
      # column on a fifth, `│` otherwise; without them (the one-column tape),
      # a `╪` stands on the tenth row where the number would. No String is
      # built — the digit for a column is read off the number by place value.
      private def paint_row_ruler_cells(row, x0 : Int32, width : Int32, r : Int32, numbers : Bool, attr : Int64) : Nil
        digits = numbers && r > 0 && r % 10 == 0 ? decimal_digits(r) : 0
        (0...width).each do |c|
          x = x0 + c
          next if x < 0
          cell = row[x]? || break
          place = width - 1 - c # 0 at the last column
          ch = if digits > 0
                 place < digits ? '0' + (r // 10 ** place) % 10 : ' '
               elsif r == 0 || place > 0
                 ' '
               elsif r % 10 == 0
                 '╪'
               elsif r % 5 == 0
                 '┼'
               else
                 '│'
               end
          cell.set_if_changed attr, ch
        end
      end

      # The attr of a chrome slot (`::line-number`, `::ruler`, `::guide`):
      # its *sub* style when a rule (or an assignment) set it, else
      # *base_attr* faded, so the chrome reads as such under any plain
      # stylesheet.
      private def chrome_attr(sub : Style?, base_attr : Int64 = style_to_attr(style)) : Int64
        return style_to_attr(sub) if sub
        faded_chrome_attr base_attr
      end

      # *base_attr* with its foreground faded toward its background by
      # `CHROME_FADE`. (Terminal-default colors can't be mixed; those stay as
      # they are.)
      private def faded_chrome_attr(base_attr : Int64) : Int64
        bg = Attr.bg(base_attr)
        Colors.blend(base_attr, Attr.pack(0_i64, bg, bg), alpha: CHROME_FADE)
      end
    end
  end
end
