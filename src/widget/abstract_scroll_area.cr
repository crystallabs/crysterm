require "./box"

module Crysterm
  class Widget
    # Abstract base for widgets with a scrollable viewport, modeled after Qt's
    # `QAbstractScrollArea`.
    #
    # Thin grouping base: scroll machinery lives in `Widget` plus per-widget
    # scrollbar-policy defaults; this only gives the family a shared type.
    # Not interactive on its own — editable members opt in via
    # `Mixin::Interactive`.
    abstract class AbstractScrollArea < Box
      # The band this widget reserves inside its frame, between the padding
      # and the viewport — Qt's `QAbstractScrollArea::viewportMargins()`.
      # Protected as in Qt: a subclass sets it for chrome of its own
      # (`PlainTextEdit`'s line-number gutter); it is not a user-facing
      # spacing knob, that is `Style#padding`. Honored by the base content
      # pipeline (`Widget#base_render`, the shared caret and mouse geometry)
      # and by `TextEdit#paint_document`.
      @viewport_margins : Padding = Padding::ZERO

      protected def viewport_margins : Padding
        @viewport_margins
      end

      # :ditto: — Qt's `setViewportMargins()`. The frame insets derived from the
      # old box are dropped and a repaint scheduled; the content re-wraps on
      # that frame, since the wrap width changed with the insets.
      protected def viewport_margins=(margins : Padding) : Padding
        @viewport_margins = margins
        @_frame_insets = nil
        update
        margins
      end

      # The column the text is laid out in when the viewport is wider: the
      # wrap width is capped at it, and the columns left over sit beside the
      # text where `#line_wrap_column_alignment` puts them — a readable
      # measure on a wide terminal. 0 (the default) lays the text out to the
      # viewport's width. Qt's `QTextEdit::lineWrapColumnOrWidth` under
      # `FixedColumnWidth`, with one difference: Qt wraps at the column even
      # when the viewport is narrower, scrolling sideways, while here the
      # viewport stays the ceiling (wrapped rows never scroll sideways). The
      # column applies in non-wrap mode too, where Qt ignores it: the text's
      # area is the column, and a longer line scrolls within it.
      getter line_wrap_column : Int32 = 0

      # :ditto: — the next frame lays the text out in the new column.
      def line_wrap_column=(column : Int32) : Int32
        column = Math.max(column, 0)
        return column if column == @line_wrap_column
        @line_wrap_column = column
        update
        update! if window?
        column
      end

      # Where `#line_wrap_column` sits in a wider viewport: `Left` (the
      # default, as Qt lays a fixed column out), `HCenter` or `Right` — the
      # horizontal half of Qt's `QScrollArea::alignment`, which places a
      # smaller widget within its scroll area the same way.
      getter line_wrap_column_alignment : Tput::AlignFlag = Tput::AlignFlag::Left

      # :ditto:
      def line_wrap_column_alignment=(alignment : Tput::AlignFlag) : Tput::AlignFlag
        return alignment if alignment == @line_wrap_column_alignment
        @line_wrap_column_alignment = alignment
        update
        update! if window?
        alignment
      end

      # The `{left, right}` columns `#line_wrap_column` leaves beside the
      # text this frame — the column's placement, as insets. Zero without a
      # column or in a viewport no wider than it.
      @column_margins = {0, 0}

      # Lays the text out in `#line_wrap_column` first: the column's insets
      # are derived from the width the content is about to be wrapped to,
      # ahead of the wrap, so this frame's `#ileft`/`#ihorizontal` — and with
      # them the wrap width, the painted origin and the caret and mouse
      # geometry — already include them.
      def process_content(no_tags = false, awidth_hint : Int32? = nil)
        sync_line_wrap_column(awidth_hint || awidth) if window?
        super
      end

      # Recomputes `@column_margins` for a box *width* cells wide: the text
      # area left after the frame, the chrome and the reserved right-edge
      # columns (`#content_margin_x`, the scroll bar) is the column at most,
      # and the slack is split by the alignment. A changed pair drops the
      # cached frame insets, which the next inset read rebuilds with it. The
      # scroll bar's reservation is the previous frame's: a bar that appears
      # or goes shifts the text by its width for one frame, and the next
      # frame settles — the text keeps its width either way, so the bar's
      # presence does not flip back.
      private def sync_line_wrap_column(width : Int32) : Nil
        left, right = @column_margins
        new_left = new_right = 0
        if (column = @line_wrap_column) > 0
          slack = width - ihorizontal + left + right - content_margin_x - column
          if slack > 0
            align = @line_wrap_column_alignment
            new_left = align.h_center? ? slack // 2 : align.right? ? slack : 0
            new_right = slack - new_left
          end
        end
        return if new_left == left && new_right == right
        @column_margins = {new_left, new_right}
        @_frame_insets = nil
      end

      # The column's insets ride on the viewport margins: the same band
      # between the padding and the text, insetting the wrap width, the
      # content origin and the geometry alike. A widget-owned box, rewritten
      # per call like the base's, so the margins may change between frames
      # without an allocation.
      protected def padding_with_viewport_margins : Padding
        box = super
        left, right = @column_margins
        return box if left == 0 && right == 0
        own = (@_padding_with_column ||= Padding.new(0))
        own.left = box.left + left
        own.top = box.top
        own.right = box.right + right
        own.bottom = box.bottom
        own
      end

      @_padding_with_column : Padding?

      # The scroll bars stay at the frame, outside the viewport margins and
      # the column's insets, as Qt's do: the bars are pinned to the inner
      # box, which the margins inset, so each is pulled back out by the
      # margins on its edges and stretched by the ones along its length.
      protected def update_scrollbar_widget(show_v : Bool? = nil, show_h : Bool? = nil) : Nil
        show_v = show_scrollbar? if show_v.nil?
        show_h = show_horizontal_scrollbar? if show_h.nil?
        super show_v, show_h
        vm = viewport_margins
        left, right = @column_margins
        left += vm.left
        right += vm.right
        return unless left > 0 || right > 0 || vm.top > 0 || vm.bottom > 0
        if show_v && (sb = @scrollbar_widget)
          sb.right = -right
          sb.top = -vm.top
          sb.height = Dim.percent(100, vm.top + vm.bottom - (show_h ? scrollbar_height : 0))
        end
        if show_h && (hb = @horizontal_scrollbar_widget)
          hb.left = -left
          hb.bottom = -vm.bottom
          hb.width = Dim.percent(100, left + right - (show_v ? scrollbar_width : 0))
        end
      end
    end
  end
end
