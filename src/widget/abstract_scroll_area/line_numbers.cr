module Crysterm
  class Widget
    abstract class AbstractScrollArea
      # A line-number gutter — the `LineNumberArea` of Qt's code editor
      # example, built in here as a view property — shows with
      # `#line_numbers = true`, on any scroll area: a band down the left of
      # the viewport, reserved through `#viewport_margins` (the outer band;
      # the row ruler, when shown, stands between it and the text), each
      # line's 1-based number right-aligned in it with a space before the
      # text. The gutter is as wide as the line count's digits (two at least)
      # plus the space, growing past 99 and 999 lines, and the text lays out
      # in the width left of it; the caret, mouse hit-testing, selections,
      # pictures and the horizontal scroll all count from the text's edge.
      #
      # What a line is, is the widget's to say (`#line_number_at`,
      # `#line_number_count`): by default every row of the laid-out content
      # is one, numbered 1 to N from the top of the document — for a rich
      # text view (`TextEdit`, `TextBrowser`) the rendered rows as shown,
      # wrapped rows and the blank rows between blocks each counted, since a
      # rendered document has no lines of its own to number, and so the
      # numbers follow the layout as it re-wraps. `PlainTextEdit` numbers its
      # source lines instead, on each line's first row, the rows a wrapped
      # line continues on left blank.
      #
      # The current line (`#current_line_number`, the caret's) keeps the
      # widget's own foreground; the others take the `::line-number`
      # sub-style (`AbstractScrollArea::line-number { color: … }` — muted in
      # the default theme), or with no rule the widget's foreground faded
      # toward its background. A row tinted whole (the current-line tint, a
      # full-width extra selection) carries the tint across its gutter cells
      # (`#chrome_row_attr`), so it reads as one bar.
      # `Event::LineNumbersChanged` follows the toggle, for a View menu entry
      # bound to it (`Action#bind_checked`).
      #
      # ```
      # editor = Widget::PlainTextEdit.new parent: s, content: File.read(path)
      # editor.line_numbers = true
      # ```
      #
      # Whether the line-number gutter is shown. Off by default. Qt's
      # `QPlainTextEdit` has no such property — its code editor example
      # composes the gutter from `setViewportMargins` and a child widget — so
      # this is Crysterm's own, as a view property that a menu entry can
      # toggle.
      getter? line_numbers : Bool = false

      # :ditto: — emits `Event::LineNumbersChanged` on an actual change. The
      # gutter's columns are reserved (or released) at once, so the next frame
      # already lays the text out in the width left.
      def line_numbers=(value : Bool) : Bool
        return value if value == @line_numbers
        @line_numbers = value
        sync_line_number_width
        # The row ruler's answer to `#row_ruler_numbers?` just flipped: its
        # band is re-reserved now, so the same frame lays out beside it.
        sync_ruler_width if @row_ruler
        emit Crysterm::Event::LineNumbersChanged, value
        update
        update! if window?
        value
      end

      # Fewest digit columns the gutter shows, so it doesn't jitter between
      # 9 and 10 lines on a short document.
      LINE_NUMBER_MIN_DIGITS = 2

      # How far the gutter's foreground fades toward the background when no
      # `::line-number` rule styles it: the weight of the text color in the
      # mix.
      LINE_NUMBER_FADE = 0.55

      # Columns the gutter reserves right now (`#line_number_area_width`),
      # 0 while `#line_numbers?` is off. Mirrored into `#viewport_margins`.
      @line_number_width = 0

      # Columns the gutter takes while shown — the digits of the line count
      # (`LINE_NUMBER_MIN_DIGITS` at least) plus the space before the text —
      # and 0 while hidden. The Qt example's `lineNumberAreaWidth()`.
      def line_number_area_width : Int32
        @line_number_width
      end

      # How many lines the gutter numbers, which sets its width: the rows of
      # the last layout by default (see the section comment).
      protected def line_number_count : Int32
        @wrapped_lines.size
      end

      # The number the gutter shows on document row *rl* (0-based, among the
      # laid-out rows), or 0 to leave the row blank: every row its own,
      # 1-based, by default.
      protected def line_number_at(rl : Int32) : Int32
        rl >= 0 && rl < @wrapped_lines.size ? rl + 1 : 0
      end

      # The line whose number keeps the widget's own foreground (the caret's
      # line), or 0 for none — none here.
      protected def current_line_number : Int32
        0
      end

      # The attr the margin chrome's cells on document row *rl* — the
      # gutter's and the row ruler's — are written in, given their own
      # *attr*: that one by default. A subclass that tints whole rows (the
      # current line, a full-width selection) carries the tint across here,
      # so the gutter, the ruler and the text read as one bar.
      protected def chrome_row_attr(rl : Int32, attr : Int64) : Int64
        attr
      end

      # The row ruler numbers the rows only while the gutter does not: with
      # the line numbers on it is a one-column tape of ticks beside them.
      protected def row_ruler_numbers? : Bool
        !@line_numbers
      end

      # Re-reserves the gutter's columns from `#line_number_count` (the Qt
      # example's `updateLineNumberAreaWidth`, which it runs on
      # `blockCountChanged`): on the toggle, before each layout and after
      # one that changed the count's digits. Returns whether the width
      # changed — a no-op otherwise, which is nearly every frame.
      protected def sync_line_number_width : Bool
        w = @line_numbers ? Math.max(decimal_digits(line_number_count), LINE_NUMBER_MIN_DIGITS) + 1 : 0
        return false if w == @line_number_width
        @line_number_width = w
        self.viewport_margins = w.zero? ? Padding::ZERO : Padding.left(w)
        true
      end

      # Paints the gutter after the base render: the band is
      # `#viewport_margins` wide, left of the content and right of the border
      # and padding, and the base render already filled it with the widget's
      # background. Each row `#line_number_at` gives a number gets it,
      # right-aligned before the gap column (`lineNumberAreaPaintEvent` of
      # the Qt example); the others, and the rows past the end, stay blank.
      private def paint_line_numbers : Nil
        lp = @lpos || return
        w = @line_number_width
        sb = style.border_view
        pd = style.padding_view
        # On a scroll-clipped left edge only the gutter's visible remainder is
        # on window (the same per-edge fit `base_render` applies), and that is
        # its right part: `hidden` leading columns of each number are cut.
        # Of the rulers' band (`#rulers=`) only the column ruler's row is
        # outside the gutter's, above it; the row ruler's columns come after
        # the gutter, between it and the text.
        rulers_top = @column_ruler ? 1 : 0
        ebl, epl = effective_edge_insets(sb.left, pd.left, lp.hidden_left)
        shown = effective_edge_insets(sb.left, pd.left + w, lp.hidden_left)[1] - epl
        return if shown <= 0
        hidden = w - shown
        x0 = lp.xi + ebl + epl
        ebt, ept = effective_edge_insets(sb.top, pd.top + rulers_top, lp.hidden_top)
        ebb, epb = effective_edge_insets(sb.bottom, pd.bottom, lp.hidden_bottom)
        yi = lp.yi + ebt + ept
        yl = lp.yl - ebb - epb - hscrollbar_rows

        rows = window.cell_rows
        base_attr = style_to_attr(style)
        dim_attr = line_number_attr(base_attr)
        current = current_line_number
        (yi...yl).each do |y|
          # A negative row index would count from the window's bottom.
          next if y < 0
          row = rows[y]? || break
          rl = lp.base + (y - yi)
          number = line_number_at(rl)
          next if number <= 0
          attr = chrome_row_attr(rl, number == current ? base_attr : dim_attr)
          paint_line_number row, x0, hidden, w, number, attr
        end
      end

      # Writes *number* into *row* over the gutter's visible columns
      # (`hidden...width` of the band, at *x0* on): the digits end right
      # before the gap column, blanks lead. No String is built — the digit for
      # a column is read off the number by place value.
      private def paint_line_number(row, x0 : Int32, hidden : Int32, width : Int32, number : Int32, attr : Int64) : Nil
        digits = decimal_digits(number)
        (hidden...width).each do |c|
          x = x0 + c - hidden
          next if x < 0
          cell = row[x]? || break
          place = width - 2 - c # 0 at the units digit, -1 at the gap column
          ch = place >= 0 && place < digits ? '0' + (number // 10 ** place) % 10 : ' '
          cell.set_if_changed(attr, ch)
        end
      end

      # The gutter's attr: the `::line-number` sub-style when a rule (or an
      # assignment) set it, else the widget's own colors with the foreground
      # faded toward the background by `LINE_NUMBER_FADE`, so the numbers
      # read as chrome under any plain stylesheet. (Terminal-default colors
      # can't be mixed; those stay as they are.)
      private def line_number_attr(base_attr : Int64) : Int64
        if sub = style.line_number?
          return style_to_attr(sub)
        end
        bg = Attr.bg(base_attr)
        Colors.blend(base_attr, Attr.pack(0_i64, bg, bg), alpha: LINE_NUMBER_FADE)
      end
    end
  end
end
