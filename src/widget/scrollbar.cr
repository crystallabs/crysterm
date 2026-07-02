require "./abstract_slider"

module Crysterm
  class Widget
    # Standalone scroll bar, modeled after Qt's `QScrollBar`.
    #
    # On its own it is a draggable position control: an integer `#value` in
    # `[#minimum, #maximum]` with a proportional thumb sized from `#page_step`,
    # moved by dragging/clicking the trough, arrow keys, Page Up/Down, or the
    # wheel. Emits `Event::ValueChange` on every change.
    #
    # More usefully, it binds to a scrollable widget via `#attach`: the bar
    # then reflects and drives that widget's scroll position through the
    # existing scroll machinery (`Widget#scroll_to`/`#child_base`/`Event::Scroll`
    # from `widget_scrolling.cr`). This is the scroll bar every scrollable
    # widget uses — `Widget#ensure_scrollbar_widget` creates one as a `fixed`
    # child, `#update_scrollbar_widget` shows/hides it per policy. The bar is
    # `#scrollbar_width` columns (vertical) / `#scrollbar_height` rows
    # (horizontal) thick, never assumed to be `1`. Can also be created directly
    # and `#attach`ed for a standalone bar (e.g. beside a `Box`).
    #
    # ```
    # box = Widget::ScrollableBox.new parent: window, top: 0, left: 0, width: 40, height: 10, content: long_text
    # sb = Widget::ScrollBar.new parent: window, top: 0, left: 40, width: 1, height: 10
    # sb.attach box
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ScrollBar screenshot](../../tests/widget/scrollbar/scrollbar.5s.apng)
    # <!-- /widget-examples:capture -->
    class ScrollBar < AbstractSlider
      # A scroll bar draws a fixed-size trough; it must not shrink to its content.
      @resizable = false

      property orientation : Tput::Orientation = :vertical

      # Size of one "page" (Qt's `pageStep`): the visible span, which also sizes
      # the thumb. Page Up/Down move by this much. Changing it emits
      # `Event::RangeChange` so a bound area can react to the thumb resize.
      getter page_step : Int32 = 1

      # :ditto:
      def page_step=(v : Int32) : Int32
        return v if v == @page_step
        @page_step = v
        emit Crysterm::Event::RangeChange, @minimum, @maximum
        request_render
        v
      end

      # Qt's `QAbstractSlider#tracking`: when `true` (the default), `#value`
      # updates live as the thumb is dragged. When `false`, dragging updates
      # only `#slider_position` (and the rendered thumb), committing to `#value`
      # on release.
      property? tracking : Bool = true

      # Live thumb position while an untracked drag is in progress; `nil`
      # otherwise (in which case `#slider_position` falls back to `#value`).
      @slider_position : Int32? = nil

      # Qt's `sliderPosition`: the thumb's current position. Equal to `#value`
      # except mid-drag when `tracking?` is `false`.
      def slider_position : Int32
        @slider_position || @value
      end

      # Moves the thumb to *v*. With `tracking?` this commits straight to
      # `#value`; without it the thumb moves but `#value` stays put until
      # release.
      def slider_position=(v : Int32) : Int32
        v = v.clamp(@minimum, @maximum)
        if tracking?
          self.value = v
        else
          @slider_position = v
          request_render
        end
        v
      end

      # Glyphs for the thumb and the trough.
      property thumb_char : Char = '█'
      property trough_char : Char = '░'

      # Whether the trough (track on either side of the thumb) is painted with
      # `#trough_char`. On by default (Qt-style, full track). Set `false` for a
      # blessed-style bar drawing only the thumb. Thumb and stepper buttons are
      # unaffected; trough color still comes from `::groove`/`track` when shown.
      property? show_trough : Bool = true

      # Qt's `QScrollBar` stepper buttons (`::sub-line`/`::add-line`). Off by
      # default. When on, one cell at each end of the trough becomes a clickable
      # step button drawing an arrow glyph (see `#up_arrow_char` …), styleable
      # via the `::up-arrow`/`::down-arrow`/`::left-arrow`/`::right-arrow` and
      # `::sub-line`/`::add-line` CSS slots; the trough shrinks by two cells.
      property? stepper_buttons : Bool = false

      # Arrow glyphs drawn in the stepper buttons. Up/down are used when
      # `#orientation` is vertical, left/right when horizontal.
      property up_arrow_char : Char = '▲'
      property down_arrow_char : Char = '▼'
      property left_arrow_char : Char = '◀'
      property right_arrow_char : Char = '▶'

      # The scrollable widget this bar is bound to (see `#attach`), if any.
      getter target : Widget?

      # Guards against the bar↔target feedback loop.
      @syncing = false

      @ev_target_scroll : ::Crysterm::Event::Scroll::Wrapper?

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @page_step = 1,
        @orientation = @orientation,
        @thumb_char = '█',
        @trough_char = '░',
        @stepper_buttons = false,
        @show_trough = true,
        **input,
      )
        super **input

        # Guarded range+value init (mirrors `Slider`/`Dial`): a directly-assigned
        # `minimum`/`maximum` could otherwise store an inverted range and leave
        # `#value` stuck after `clamp`.
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress

        on(Crysterm::Event::Mouse) do |e|
          # Wheel steps the value (inverted: wheel-up scrolls toward the top =
          # smaller value). Shared with the other ranged widgets.
          next if ranged_wheel e, invert: true

          # Commit an untracked drag on release.
          if e.action.up?
            if (p = @slider_position)
              @slider_position = nil
              self.value = p
              e.accept
              request_render
            end
            next
          end

          next unless e.action.down? || (e.action.move? && !e.button.none?)
          if @orientation.horizontal?
            raw = e.x - aleft - ileft
            inner = awidth - iwidth
          else
            raw = e.y - atop - itop
            inner = aheight - iheight
          end
          steppers = stepper_buttons? && inner >= 3
          # A click on a stepper-button cell steps by `#step` instead of seeking.
          if steppers && e.action.down? && (raw <= 0 || raw >= inner - 1)
            raw <= 0 ? decrement : increment
            e.accept
            request_render
            next
          end
          # Seek within the trough, which starts one cell in when steppers show.
          pos = raw - (steppers ? 1 : 0)
          span = (steppers ? inner - 2 : inner) - 1
          next if span <= 0
          self.slider_position = @minimum + (pos.clamp(0, span) * value_span / span.to_f).round.to_i
          # Capture the mouse so an untracked drag that leaves our bounds still
          # delivers its release here — the commit below (on `up`) only fires on
          # a report the bar receives, so without capture a release off the bar
          # would strand the pending `@slider_position` uncommitted.
          if @slider_position
            window?.try &.capture_mouse(self)
          end
          e.accept
          request_render
        end
      end

      # Binds this bar to *widget* so it reflects and drives *widget*'s scroll
      # position. Recomputes the range from the widget's content/visible size and
      # syncs to its current position immediately.
      def attach(widget : Widget) : Nil
        detach
        @target = widget
        @ev_target_scroll = widget.on(::Crysterm::Event::Scroll) { sync_from_target }
        sync_from_target
      end

      # Unbinds from the current target (if any).
      def detach : Nil
        if (t = @target) && (w = @ev_target_scroll)
          t.off ::Crysterm::Event::Scroll, w
        end
        @ev_target_scroll = nil
        @target = nil
      end

      # Recomputes range/page from the target's geometry and mirrors its
      # current scroll offset onto `#value`, without driving the target back.
      def sync_from_target : Nil
        t = @target
        return unless t
        if @orientation.horizontal?
          visible = t.content_width
          total = t.get_scroll_width
          pos = t.get_scroll_x
        else
          visible = t.visible_content_rows
          total = t.get_scroll_height
          pos = t.get_scroll
        end
        @syncing = true
        @page_step = Math.max(1, visible)
        # `set_range` re-clamps and emits `Event::RangeChange`; `@syncing` keeps
        # the value re-clamp from driving the target back.
        set_range 0, Math.max(0, total - visible)
        # Mirror the engine's scroll position along this bar's axis (vertical:
        # `child_base + child_offset`; horizontal: `child_base_x`).
        self.value = pos.clamp(@minimum, @maximum)
        @syncing = false
        request_render
      rescue
        # Target not laid out yet.
      end

      # Drives the bound target when the bar moves (mixin hook). A committed
      # value supersedes any pending untracked drag. Routes to the matching axis.
      protected def on_value_changed
        @slider_position = nil
        return if @syncing
        if @orientation.horizontal?
          @target.try &.scroll_x_to(@value)
        else
          @target.try &.scroll_to(@value)
        end
      end

      # Thumb length in cells, proportional to the visible page.
      private def thumb_size(avail : Int32) : Int32
        return avail if value_span <= 0
        total = value_span + @page_step
        size = (avail * @page_step / total.to_f).round.to_i
        size.clamp(1, avail)
      end

      # Offset (in cells) of the thumb's leading edge within `avail` cells.
      private def thumb_offset(avail : Int32) : Int32
        return 0 if value_span <= 0
        room = avail - thumb_size(avail)
        ((slider_position - @minimum) * room / value_span.to_f).round.to_i.clamp(0, Math.max(0, room))
      end

      # Resolves a sub-style slot to *fallback* when not explicitly styled. The
      # `Style` slot getters return the bar's own `base` style in that case, so
      # object identity tells "unset" apart — letting e.g. `::sub-page` inherit
      # `::groove` (`track`), and the arrows inherit their `::sub-line`/`::add-line` button.
      private def resolve_slot(slot : Style, fallback : Style, base : Style) : Style
        slot.same?(base) ? fallback : slot
      end

      # Packed attr + glyph for a stepper button. The arrow slot falls back to
      # its button slot, which falls back to the bar's base style.
      private def stepper_cell(decrement : Bool, base : Style) : {Int64, Char}
        if decrement
          button = resolve_slot(base.sub_line, base, base)
          if @orientation.horizontal?
            {sattr(resolve_slot(base.left_arrow, button, base)), @left_arrow_char}
          else
            {sattr(resolve_slot(base.up_arrow, button, base)), @up_arrow_char}
          end
        else
          button = resolve_slot(base.add_line, base, base)
          if @orientation.horizontal?
            {sattr(resolve_slot(base.right_arrow, button, base)), @right_arrow_char}
          else
            {sattr(resolve_slot(base.down_arrow, button, base)), @down_arrow_char}
          end
        end
      end

      def render
        base = style
        with_inner_coords do |xi, xl, yi, yl|
          horizontal = @orientation.horizontal?
          main_lo, main_hi = horizontal ? {xi, xl} : {yi, yl}
          avail_full = main_hi - main_lo
          next if avail_full <= 0

          # Reserve a cell at each end for stepper buttons when there's room.
          steppers = stepper_buttons? && avail_full >= 3
          trough_lo = steppers ? main_lo + 1 : main_lo
          trough_hi = steppers ? main_hi - 1 : main_hi
          avail = trough_hi - trough_lo

          off = thumb_offset avail
          sz = thumb_size avail
          thumb_lo = trough_lo + off
          thumb_hi = thumb_lo + sz

          # `::sub-page`/`::add-page` are the trough above/below the handle; both
          # fall back to `::groove` (`track`) when unset.
          sub_page_attr = sattr resolve_slot(base.sub_page, base.track, base)
          add_page_attr = sattr resolve_slot(base.add_page, base.track, base)
          thumb_attr = sattr base.indicator

          # With the trough hidden (blessed-style), only the thumb is drawn; a
          # space keeps the reserved column empty rather than glyph-filled.
          trough_ch = show_trough? ? @trough_char : ' '

          (main_lo...main_hi).each do |m|
            attr, ch =
              if steppers && m == main_lo
                stepper_cell true, base
              elsif steppers && m == main_hi - 1
                stepper_cell false, base
              elsif m < thumb_lo
                {sub_page_attr, trough_ch}
              elsif m >= thumb_hi
                {add_page_attr, trough_ch}
              else
                {thumb_attr, @thumb_char}
              end
            paint_cross horizontal, m, xi, xl, yi, yl, attr, ch
          end
        end
      end

      # Fills the cross-axis extent at main-axis position *m* with *attr*/*ch*:
      # for a vertical bar *m* is a row (fill columns `xi...xl`); for a
      # horizontal bar *m* is a column (fill rows `yi...yl`).
      # A contiguous 1-cell-thick run across the cross axis, so it goes through
      # the batched `fill_region` (skips unchanged cells, narrow dirty range)
      # rather than a per-cell loop.
      private def paint_cross(horizontal, m, xi, xl, yi, yl, attr, ch) : Nil
        if horizontal
          window.fill_region attr, ch, m, m + 1, yi, yl
        else
          window.fill_region attr, ch, xi, xl, m, m + 1
        end
      end

      # Up/Left (and `k`/`h`) step toward the top/start, Down/Right (and `j`/`l`)
      # toward the bottom/end, Page Up/Down by `#page_step`, Home/End to the
      # bounds — the invert-aware stepping shared with `Slider`/`Dial`. (This
      # replaces a hand-rolled copy that had never gained the vi keys.)
      def on_keypress(e)
        ranged_step_key e, invert: true
      end

      def destroy
        detach
        super
      end
    end
  end
end
