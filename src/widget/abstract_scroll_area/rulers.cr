module Crysterm
  class Widget
    abstract class AbstractScrollArea
      # Rulers: a column ruler along the viewport's top row and a row ruler
      # down its leftmost columns, shown with `#rulers = true`. Qt's
      # `QAbstractScrollArea` has none; the margins of QScintilla and the
      # rulers Qt Designer's form editor hangs on its canvas are the nearest
      # kin, and like them the rulers are chrome of the view's own, reserved
      # through `#viewport_margins` (the band `PlainTextEdit`'s line-number
      # gutter sits in; with both shown the ruler is the outer one), so the
      # text lays out, scrolls and takes the mouse below and right of them.
      #
      # The column ruler counts in the text's own coordinates — column 1 is
      # the text's first column wherever `#line_wrap_column` and its
      # alignment put it, and a horizontal scroll slides the numbers with the
      # text — as a tape of `─` with a `┼` every fifth column and a `│` on
      # every tenth with its number right after it, so the mark itself is on
      # the column named (`│20` marks column 20). The row ruler
      # counts the document's rows the same way, numbering the visible ones
      # from the top of the document, so it tells where the view is where the
      # gutter tells which source line a row came from; it is as wide as the
      # row count's digits (two at least). A guide (`#guides_enabled=`) hangs
      # from the column ruler as a `┬`, and is pulled off it with the mouse.
      # `AbstractScrollArea::ruler { color: … }` styles the rulers; with no
      # rule they fade the widget's own foreground toward its background, the
      # way the gutter does. `Event::RulersChanged` follows the toggle, for a
      # View menu entry bound to it. The two are also switched one at a
      # time (`#column_ruler=`, `#row_ruler=`), for a view that wants the
      # column count without a band down its left, or the other way round.
      getter? column_ruler : Bool = false

      # Whether the row ruler is shown; see `#rulers=`.
      getter? row_ruler : Bool = false

      # Whether either ruler is shown.
      def rulers? : Bool
        @column_ruler || @row_ruler
      end

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

      # Fewest columns the row ruler takes, so a short document's ruler does
      # not jitter between 9 and 10 rows.
      RULER_MIN_DIGITS = 2

      # How far a ruler's or a guide's foreground fades toward the background
      # when no `::ruler`/`::guide` rule styles it: the weight of the text
      # color in the mix (`PlainTextEdit::LINE_NUMBER_FADE`'s twin).
      CHROME_FADE = 0.55

      # Columns the row ruler takes this frame, 0 while `#row_ruler?` is
      # off; the column ruler's row is `#column_ruler?` itself.
      @vertical_ruler_width = 0

      # The row ruler's width, in columns: the row count's digits, so a
      # thousand-row document gets a fourth column (`RULER_MIN_DIGITS` at
      # least). Re-derived before each layout (`#process_content`) from the
      # rows the last one produced — the count can only change with a new
      # layout, and a width that grows by it settles the frame after, as the
      # scroll bar's reservation does.
      private def sync_ruler_width : Nil
        w = @row_ruler ? Math.max(decimal_digits(@wrapped_lines.size), RULER_MIN_DIGITS) : 0
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
      # first column and the row the column ruler is on (the padding's inner
      # edge), the interior's exclusive right and bottom edges with the scroll
      # bars kept out, the screen column the text's column 1 is at (before
      # the horizontal scroll) and the first content row. The same arithmetic
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
        xl = lp.xl - iright - (show_scrollbar? ? scrollbar_width : 0)
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
      # and the row ruler down the content rows. The base render filled the
      # band with the widget's background; both are written in
      # `#ruler_attr`. Columns before the text's first (the gutter, a
      # centered column's left slack) and rows past the document's end stay
      # blank.
      private def paint_rulers : Nil
        lp = @lpos || return
        x0, xl, y0, yl, text_x0, content_top = chrome_frame || return
        return if xl <= x0 || yl <= y0
        rows = window.cell_rows
        attr = ruler_attr
        vw = @vertical_ruler_width
        if @column_ruler && y0 >= 0 && (row = rows[y0]?)
          (x0 + vw...xl).each do |x|
            next if x < 0
            cell = row[x]? || break
            cell.set_if_changed attr, column_ruler_glyph(text_column_at(x, text_x0))
          end
        end
        return if vw == 0
        total = @wrapped_lines.size
        (content_top...yl).each do |y|
          next if y < 0
          row = rows[y]? || break
          r = lp.base + (y - content_top) + 1
          paint_row_ruler_cells row, x0, vw, (r <= total ? r : 0), attr
        end
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
      # row *r* (1-based; 0 for a row past the end, left blank): the number
      # right-aligned on a tenth row, a `┼` in the last column on a fifth,
      # `│` otherwise. No String is built — the digit for a column is read
      # off the number by place value.
      private def paint_row_ruler_cells(row, x0 : Int32, width : Int32, r : Int32, attr : Int64) : Nil
        digits = r > 0 && r % 10 == 0 ? decimal_digits(r) : 0
        (0...width).each do |c|
          x = x0 + c
          next if x < 0
          cell = row[x]? || break
          place = width - 1 - c # 0 at the last column
          ch = if digits > 0
                 place < digits ? '0' + (r // 10 ** place) % 10 : ' '
               elsif r == 0 || place > 0
                 ' '
               elsif r % 5 == 0
                 '┼'
               else
                 '│'
               end
          cell.set_if_changed attr, ch
        end
      end

      # The rulers' attr: the `::ruler` sub-style when a rule (or an
      # assignment) set it, else the widget's own colors with the foreground
      # faded toward the background by `CHROME_FADE`, so the rulers read as
      # chrome under any plain stylesheet.
      private def ruler_attr : Int64
        if sub = style.ruler?
          return style_to_attr(sub)
        end
        faded_chrome_attr style_to_attr(style)
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
