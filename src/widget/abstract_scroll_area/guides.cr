module Crysterm
  class Widget
    abstract class AbstractScrollArea
      # Guides: thin vertical lines down the viewport at chosen text columns,
      # shown with `#guides_enabled = true` — the guides a design tool (and
      # Qt Designer's form editor) lets one pull off a ruler, for a text
      # view. Two are automatic, the bounds of the text's column: the column
      # just before the text and the one just after it (`#text_column_bounds`,
      # 0 and the text width plus one), which with `#line_wrap_column` set in
      # a wider viewport mark the capped, possibly centered, column, and
      # without it sit at the viewport's inner edges. They are always there
      # and cannot be removed; the ones in `#guides` are the user's, added by
      # hand or by the mouse. Like the rulers, the columns are the text's own,
      # so the guides slide with a horizontal scroll.
      #
      # A guide is drawn as a `│` in the cells of its column that hold no
      # text — never over a character, and keeping the cell's background, so
      # a selection or the current line's tint shows through — in the
      # `::guide` color (`AbstractScrollArea::guide { color: … }`), or the
      # widget's foreground faded like the rulers' without a rule.
      #
      # With the rulers shown, the mouse makes and moves guides the way it
      # does in a design tool: a press on the column ruler lifts the guide
      # hanging there (its `┬`), or a new one when none does, and the guide
      # follows the pointer until the button is released. Dropped on a
      # content row it stays at that column; dropped back on the ruler, or on
      # a column another guide (a bound included) already occupies, it is
      # removed — so one of two guides brought together goes, and the bounds,
      # which are not in `#guides`, survive any drop. A click on the ruler
      # that does not reach the content makes nothing. Without the rulers the
      # guides are still shown but there is nothing to pull them from.
      # `Event::GuidesChanged` reports every change to `#guides`, with the
      # columns, so an application can keep them.
      getter? guides_enabled : Bool = false

      # :ditto:
      def guides_enabled=(value : Bool) : Bool
        return value if value == @guides_enabled
        @guides_enabled = value
        update
        update! if window?
        value
      end

      # The user's guide columns, 1-based in the text's coordinates (the
      # automatic bounds are not among them), in ascending order.
      @guides = Set(Int32).new

      # The column the guide being dragged is at, while one is; see
      # `#install_guide_mouse`.
      @dragged_guide : Int32?

      # The column the dragged guide was lifted from, nil for a new one.
      @dragged_from : Int32?

      def guides : Array(Int32)
        @guides.to_a.sort!
      end

      # Replaces the user's guides with *columns*.
      def guides=(columns : Enumerable(Int32)) : Nil
        set = Set(Int32).new
        columns.each { |c| set << c if c > 0 }
        return if set == @guides
        @guides = set
        guides_changed
      end

      # Adds a guide at *column* (1-based, in the text's coordinates);
      # returns whether it was new.
      def add_guide(column : Int32) : Bool
        return false if column <= 0 || @guides.includes?(column)
        @guides << column
        guides_changed
        true
      end

      # Removes the user's guide at *column*; returns whether there was one.
      # The bounds are not the user's and are not removed.
      def remove_guide(column : Int32) : Bool
        return false unless @guides.delete(column)
        guides_changed
        true
      end

      # The automatic bound guides: the column just before the text and the
      # one just after its width — the width the text is laid out in this
      # frame, which is `#line_wrap_column` when it caps a wider viewport and
      # the viewport's text columns otherwise.
      def text_column_bounds : {Int32, Int32}
        {0, content_width + 1}
      end

      # Every guide shown this frame: the bounds, the user's and the one in
      # hand, ascending, each column once.
      def guide_columns : Array(Int32)
        columns = Set(Int32).new
        low, high = text_column_bounds
        columns << low << high
        columns.concat @guides
        @dragged_guide.try { |c| columns << c }
        columns.to_a.sort!
      end

      private def guides_changed : Nil
        emit Crysterm::Event::GuidesChanged, guides
        update
        update! if window?
      end

      # Paints the guides after the base render and the rulers: down each
      # guide's column, from the first content row to the last, in the cells
      # that hold a blank — a text cell keeps its character — with the cell's
      # own background and flags under the guide's foreground; and a `┬` on
      # the column ruler, where the guide can be taken hold of. A column
      # scrolled or laid out off the viewport (the left bound with nothing
      # before the text) draws nothing.
      private def paint_guides : Nil
        x0, xl, y0, yl, text_x0, content_top = chrome_frame || return
        return if xl <= x0 || yl <= content_top
        rows = window.cell_rows
        fg = Attr.fg(guide_attr)
        marker_attr = @column_ruler ? ruler_attr : 0_i64
        first_x = guides_first_x(x0)
        guide_columns.each do |col|
          x = text_x0 + col - 1 - @child_base_x
          next if x < first_x || x >= xl || x < 0
          (content_top...yl).each do |y|
            next if y < 0
            row = rows[y]? || break
            cell = row[x]? || break
            next unless cell.char == ' '
            a = cell.attr
            cell.set_if_changed Attr.pack(Attr.flags(a), fg, Attr.bg(a)), '│'
          end
          next unless @column_ruler && y0 >= 0
          if (row = rows[y0]?) && (cell = row[x]?)
            cell.set_if_changed marker_attr, '┬'
          end
        end
      end

      # The guides' attr: the `::guide` sub-style when a rule (or an
      # assignment) set it, else the widget's own colors faded like the
      # rulers'.
      private def guide_attr : Int64
        if sub = style.guide?
          return style_to_attr(sub)
        end
        faded_chrome_attr style_to_attr(style)
      end

      # The mouse gesture described on the class: installed at construction,
      # ahead of a text widget's own click-to-position handler, which stands
      # down from an accepted event. Only a press on the column ruler with
      # the guides shown starts anything; the widget then captures the mouse
      # so the drag may leave its box and still end here.
      private def install_guide_mouse : Nil
        on(Crysterm::Event::Mouse) do |e|
          if e.action.down?
            next unless @column_ruler && @guides_enabled
            next unless column = ruler_column_at(e.x, e.y)
            lift_guide column
            e.accept
            window?.try &.capture_mouse(self)
            update!
          elsif e.action.move?
            next unless @dragged_guide
            e.accept
            drag_guide_to column_at(e.x)
          elsif e.action.up?
            next unless @dragged_guide
            e.accept
            frame = chrome_frame
            drop_guide column_at(e.x), on_ruler: !frame.nil? && e.y == frame[2]
          end
        end
      end

      # The text column under the screen column *x*, or nil without a render.
      private def column_at(x : Int32) : Int32?
        frame = chrome_frame || return
        text_column_at x, frame[4]
      end

      # The text column at `(x, y)` when that is on the column ruler, right of
      # the row ruler and within the interior; nil anywhere else.
      private def ruler_column_at(x : Int32, y : Int32) : Int32?
        x0, xl, y0, _yl, text_x0, _top = chrome_frame || return
        # The tape starts past the subclass's own margin and the row ruler
        # (`#paint_rulers`); a press on the blank above a gutter is no press
        # on the ruler.
        return unless y == y0 && x >= x0 + @viewport_margins.left + @vertical_ruler_width && x < xl
        text_column_at x, text_x0
      end

      # The first screen column a guide is drawn in, given the band's first
      # column *x0*: the row ruler's right edge while it shows (it stands
      # right of the subclass's own margin, and a guide never runs over its
      # ticks), else the band's own first column, so the left bound may run
      # down a gutter's gap column.
      private def guides_first_x(x0 : Int32) : Int32
        vw = @vertical_ruler_width
        vw > 0 ? x0 + @viewport_margins.left + vw : x0
      end

      # Takes the guide at *column* in hand — the user's one there, lifted out
      # of `#guides` for the drag, or a new one when the column holds none
      # (a bound's column holds none the user may take, so a press there
      # starts a new guide, which a drop back on the bound removes).
      private def lift_guide(column : Int32) : Nil
        @dragged_from = @guides.delete(column) ? column : nil
        @dragged_guide = column
      end

      private def drag_guide_to(column : Int32?) : Nil
        return if column.nil? || column == @dragged_guide
        @dragged_guide = column
        update!
      end

      # Ends the drag at *column*: the guide is put down there unless it was
      # dropped back on the ruler or onto an occupied column — a bound's or
      # another guide's — in which case it is gone. `Event::GuidesChanged` is
      # emitted when the drag changed `#guides`; a guide put back where it
      # was lifted from is no change.
      private def drop_guide(column : Int32?, on_ruler : Bool) : Nil
        from = @dragged_from
        @dragged_guide = @dragged_from = nil
        low, high = text_column_bounds
        keep = column && !on_ruler && column > 0 && column != low && column != high && !@guides.includes?(column)
        @guides << column if keep && column
        if (keep ? column : nil) != from
          guides_changed
        else
          update!
        end
      end
    end
  end
end
