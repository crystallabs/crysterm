require "./abstract_slider"

module Crysterm
  class Widget
    # Standalone scroll bar, modeled after Qt's `QScrollBar`.
    #
    # On its own it is a draggable position control: an integer `#value` in
    # `[#minimum, #maximum]` with a proportional thumb sized from `#page_step`,
    # moved by dragging/clicking the trough, arrow keys, Page Up/Down, or the
    # wheel. Emits `Event::ValueChanged` on every change.
    #
    # More usefully, it binds to a scrollable widget via `#attach`: the bar then
    # reflects and drives that widget's scroll position. This is the scroll bar
    # every scrollable widget uses, and it can also be created directly and
    # `#attach`ed for a standalone bar (e.g. beside a `Box`). The bar is
    # `#scrollbar_width` columns (vertical) / `#scrollbar_height` rows
    # (horizontal) thick — never assume `1`.
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
      property orientation : Tput::Orientation = :vertical

      # Size of one "page" (Qt's `pageStep`): the visible span, which also sizes
      # the thumb. Page Up/Down move by this much. Changing it emits
      # `Event::RangeChanged` so a bound area can react to the thumb resize.
      getter page_step : Int32 = 1

      # :ditto:
      def page_step=(v : Int32) : Int32
        return v if v == @page_step
        @page_step = v
        emit Crysterm::Event::RangeChanged, @minimum, @maximum
        request_render
        v
      end

      # Glyphs for the thumb and the trough. Unset (`nil`) resolves the CSS
      # `glyph` on the matching sub-control (`ScrollBar::handle`/`::indicator`
      # for the thumb, `::add-page`/`::groove`/`track` for the trough), then
      # the `Glyphs` registry at the effective tier; assigning a `Char` pins it.
      setter thumb_char : Char? = nil
      setter trough_char : Char? = nil

      # :ditto:
      def thumb_char : Char
        @thumb_char || glyph(Glyphs::Role::ScrollThumb, style.raw_sub_style("indicator"))
      end

      # :ditto:
      def trough_char : Char
        @trough_char || glyph(Glyphs::Role::ScrollTrough,
          style.raw_sub_style("add-page") || style.raw_sub_style("track"))
      end

      # Minimum thumb (handle) length in cells, so the proportional handle never
      # collapses to an unusable single-cell nub over a very long list — Qt's
      # `QStyle::PM_ScrollBarSliderMin`. Defaults to `1` (pure proportional); the
      # list-like item views bump it. Always clamped down to the available track,
      # so a tiny bar still fits.
      property min_thumb : Int32 = 1

      # Whether the trough (track on either side of the thumb) is painted with
      # `#trough_char`. On by default (Qt-style, full track). Set `false` for a
      # blessed-style bar drawing only the thumb. Thumb and stepper buttons are
      # unaffected; trough color still comes from `::groove`/`track` when shown.
      property? show_trough : Bool = true

      # Qt's `QScrollBar` stepper buttons (`::sub-line`/`::add-line`). Off by
      # default. When on, one cell at each end of the trough becomes a clickable
      # step button drawing an arrow glyph, styleable
      # via the `::up-arrow`/`::down-arrow`/`::left-arrow`/`::right-arrow` and
      # `::sub-line`/`::add-line` CSS slots; the trough shrinks by two cells.
      property? stepper_buttons : Bool = false

      # Arrow glyphs drawn in the stepper buttons. Up/down are used when
      # `#orientation` is vertical, left/right when horizontal. Unset (`nil`)
      # resolves the CSS `glyph` on the matching `::up-arrow`/… slot, then the
      # `Glyphs` registry at the effective tier.
      setter up_arrow_char : Char? = nil
      setter down_arrow_char : Char? = nil
      setter left_arrow_char : Char? = nil
      setter right_arrow_char : Char? = nil

      # :ditto:
      def up_arrow_char : Char
        @up_arrow_char || glyph(Glyphs::Role::ArrowUp, style.raw_sub_style("up-arrow"))
      end

      # :ditto:
      def down_arrow_char : Char
        @down_arrow_char || glyph(Glyphs::Role::ArrowDown, style.raw_sub_style("down-arrow"))
      end

      # :ditto:
      def left_arrow_char : Char
        @left_arrow_char || glyph(Glyphs::Role::ArrowLeft, style.raw_sub_style("left-arrow"))
      end

      # :ditto:
      def right_arrow_char : Char
        @right_arrow_char || glyph(Glyphs::Role::ArrowRight, style.raw_sub_style("right-arrow"))
      end

      # The scrollable widget this bar is bound to (see `#attach`), if any.
      getter target : Widget?

      # Guards against the bar↔target feedback loop.
      @syncing = false

      # Last `{page_step, minimum, maximum, value}` pushed by `#sync_from_target`,
      # so a scroll event that resolves to the same geometry is a no-op instead of
      # re-assigning and requesting a render.
      @last_synced : Tuple(Int32, Int32, Int32, Int32)?

      # Subscription to the target's `Scroll`, torn down in `#detach`. It captures
      # the target it was installed on, so `#off` reaches that exact widget
      # regardless of `@target`'s later state.
      @ev_target_scroll = ::Crysterm::Subscription.new

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @page_step = 1,
        @orientation = @orientation,
        @thumb_char = nil,
        @trough_char = nil,
        @stepper_buttons = false,
        @show_trough = true,
        **input,
      )
        super **input

        # Never store an inverted range; it would leave `#value` stuck after `clamp`.
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress

        on(Crysterm::Event::Mouse) do |e|
          # Wheel steps the value, inverted: wheel-up scrolls toward the top, i.e.
          # a smaller value.
          next if ranged_wheel e, invert: true

          # Commit an untracked drag on release.
          if e.action.up?
            e.accept if commit_slider_position
            next
          end

          next unless e.action.down? || (e.action.move? && !e.button.none?)
          # Resolve the pointer against the *painted* track when rendered. Mouse
          # events are dispatched by painted geometry, which inside a scrolled
          # container is shifted from the layout coords by the ancestor's scroll
          # base, and an ancestor-clipped bar paints its whole track compressed
          # into the clipped rect. Both the origin and the span must come from
          # that same rect or a seek lands on the wrong value. Falls back to
          # layout coords before the first render.
          if lp = @lpos
            txi, txl, tyi, tyl = lp.xi, lp.xl, lp.yi, lp.yl
            if border = style.border
              # Inset by the *visible* border remainder per edge: an ancestor
              # clip may hide part of the border band (recorded in `lp.hidden_*`),
              # so subtracting the full width would double-count the clipped
              # cells and land a seek on the wrong value. Padding stays out of
              # this branch (border-only, mirroring its original `border.adjust`).
              txi += effective_edge_insets(border.left, 0, lp.hidden_left)[0]
              txl -= effective_edge_insets(border.right, 0, lp.hidden_right)[0]
              tyi += effective_edge_insets(border.top, 0, lp.hidden_top)[0]
              tyl -= effective_edge_insets(border.bottom, 0, lp.hidden_bottom)[0]
            end
            if @orientation.horizontal?
              raw = e.x - txi
              inner = txl - txi
            else
              raw = e.y - tyi
              inner = tyl - tyi
            end
          elsif @orientation.horizontal?
            raw = e.x - aleft - ileft
            inner = awidth - ihorizontal
          else
            raw = e.y - atop - itop
            inner = aheight - ivertical
          end
          steppers = stepper_buttons? && inner >= 3
          # A click on a stepper-button cell steps by `#single_step` instead of seeking.
          if steppers && e.action.down? && (raw <= 0 || raw >= inner - 1)
            raw <= 0 ? step_down : step_up
            e.accept
            request_render
            next
          end
          # Seek within the trough, which starts one cell in when steppers show.
          pos = raw - (steppers ? 1 : 0)
          span = (steppers ? inner - 2 : inner) - 1
          next if span <= 0
          # `pos` is clamped: a scroll bar sizes a thumb and must not seek past
          # the ends.
          self.slider_position = value_at pos.clamp(0, span), span
          # Capture the mouse so a drag that leaves the bar's (often 1-column)
          # bounds keeps delivering motion/release here instead of freezing the
          # thumb, and so an untracked drag's pending `@slider_position` can't
          # strand uncommitted on a release off the bar. Idempotent.
          window?.try &.capture_mouse(self)
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
        @ev_target_scroll.on(widget, ::Crysterm::Event::Scroll) { sync_from_target }
        sync_from_target
      end

      # Unbinds from the current target (if any).
      def detach : Nil
        @ev_target_scroll.off
        @target = nil
      end

      # Recomputes range/page from the target's geometry and mirrors its
      # current scroll offset onto `#value`, without driving the target back.
      def sync_from_target : Nil
        t = @target
        return unless t
        if @orientation.horizontal?
          visible = t.content_width
          total = t.scroll_width
          pos = t.scroll_position_x
        else
          visible = t.visible_content_rows
          total = t.scroll_height
          pos = t.scroll_position
        end
        new_page = Math.max(1, visible)
        new_max = Math.max(0, total - visible)
        new_val = pos.clamp(0, new_max)
        # Nothing changed since the last sync: skip the assignments + repaint.
        key = {new_page, 0, new_max, new_val}
        return if @last_synced == key
        @last_synced = key

        @syncing = true
        @page_step = new_page
        # `set_range` re-clamps and emits `Event::RangeChanged`; `@syncing` keeps
        # the value re-clamp from driving the target back.
        set_range 0, new_max
        # Mirror the engine's scroll position along this bar's axis.
        self.value = pos.clamp(@minimum, @maximum)
        @syncing = false
        request_render
      rescue
        # Target not laid out yet.
      end

      # Drives the bound target when the bar moves.
      protected def on_value_changed
        super
        return if @syncing
        if @orientation.horizontal?
          @target.try &.scroll_to_x(@value)
        else
          @target.try &.scroll_to(@value)
        end
      end

      # Thumb length in cells, proportional to the visible page but never shorter
      # than `#min_thumb` (down-clamped to the available track).
      private def thumb_size(avail : Int32) : Int32
        return avail if value_span <= 0
        # `value_span` saturates at `Int32::MAX` for a full-span range, so
        # `+ @page_step` and `avail * @page_step` must widen to Int64 or overflow.
        total = value_span.to_i64 + @page_step
        size = (avail.to_i64 * @page_step / total.to_f).round.to_i
        size.clamp(Math.min(@min_thumb, avail), avail)
      end

      # Offset (in cells) of the thumb's leading edge within `avail` cells.
      private def thumb_offset(avail : Int32) : Int32
        return 0 if value_span <= 0
        room = avail - thumb_size(avail)
        value_to_cell(slider_position.to_i64, room).clamp(0, Math.max(0, room))
      end

      # Resolves a sub-style slot to *fallback* when not explicitly styled. The
      # slot getters return the bar's own `base` style in that case, so object
      # identity is what tells "unset" apart.
      private def resolve_slot(slot : Style, fallback : Style, base : Style) : Style
        slot.same?(base) ? fallback : slot
      end

      # Packed attr + glyph for a stepper button. The arrow slot falls back to
      # its button slot, which falls back to the bar's base style.
      private def stepper_cell(decrement : Bool, base : Style) : {Int64, Char}
        if decrement
          button = resolve_slot(base.sub_line, base, base)
          if @orientation.horizontal?
            {style_to_attr(resolve_slot(base.left_arrow, button, base)), left_arrow_char}
          else
            {style_to_attr(resolve_slot(base.up_arrow, button, base)), up_arrow_char}
          end
        else
          button = resolve_slot(base.add_line, base, base)
          if @orientation.horizontal?
            {style_to_attr(resolve_slot(base.right_arrow, button, base)), right_arrow_char}
          else
            {style_to_attr(resolve_slot(base.down_arrow, button, base)), down_arrow_char}
          end
        end
      end

      def render(with_children = true)
        base = style
        with_inner_coords(with_children) do |xi, xl, yi, yl|
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
          sub_page_attr = style_to_attr resolve_slot(base.sub_page, base.track, base)
          add_page_attr = style_to_attr resolve_slot(base.add_page, base.track, base)
          thumb_attr = style_to_attr base.indicator

          # With the trough hidden, only the thumb is drawn; a space keeps the
          # reserved column empty rather than glyph-filled. Both glyphs hoisted
          # out of the per-cell loop: registry resolution walks to the window.
          trough_ch = show_trough? ? trough_char : ' '
          thumb_ch = thumb_char

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
                {thumb_attr, thumb_ch}
              end
            paint_cross horizontal, m, xi, xl, yi, yl, attr, ch
          end
        end
      end

      # Fills the cross-axis extent at main-axis position *m* with *attr*/*ch*:
      # for a vertical bar *m* is a row (fill columns `xi...xl`); for a
      # horizontal bar *m* is a column (fill rows `yi...yl`). A contiguous run, so
      # it goes through the batched `fill_region`, not a per-cell loop.
      private def paint_cross(horizontal, m, xi, xl, yi, yl, attr, ch) : Nil
        if horizontal
          window.fill_region attr, ch, m, m + 1, yi, yl
        else
          window.fill_region attr, ch, xi, xl, m, m + 1
        end
      end

      # Up/Left (and `k`/`h`) step toward the top/start, Down/Right (and `j`/`l`)
      # toward the bottom/end, Page Up/Down by `#page_step`, Home/End to the
      # bounds. Inverted because a scroll bar's Down/Right move toward the end,
      # unlike a plain slider.
      protected def step_key_inverted? : Bool
        true
      end

      def destroy
        detach
        super
      end
    end
  end
end
