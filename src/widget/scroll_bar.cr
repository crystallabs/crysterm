require "./abstract_slider"
require "../mixin/track_geometry"

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
      include Mixin::TrackGeometry

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
        update!
        v
      end

      # Glyph used for the thumb. Unset (`nil`) resolves the CSS `glyph` on
      # the matching sub-control (`ScrollBar::handle`/`::indicator`), then the
      # `Glyphs` registry at the effective tier; assigning a `Char` pins it.
      pinnable_glyph thumb, ScrollThumb, "indicator"

      # Glyph used for the trough (track on either side of the thumb). Unset
      # (`nil`) resolves the CSS `glyph` on `::add-page`/`::groove`/`track`
      # (in that fallback order), then the `Glyphs` registry at the effective
      # tier; assigning a `Char` pins it. Two-slot CSS fallback, so hand-rolled
      # rather than `pinnable_glyph`.
      setter trough_char : Char? = nil

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
      pinnable_glyph up_arrow, ArrowUp, "up-arrow"

      # :ditto:
      pinnable_glyph down_arrow, ArrowDown, "down-arrow"

      # :ditto:
      pinnable_glyph left_arrow, ArrowLeft, "left-arrow"

      # :ditto:
      pinnable_glyph right_arrow, ArrowRight, "right-arrow"

      # The scrollable widget this bar is bound to (see `#attach`), if any.
      getter target : Widget?

      # Guards against the bar↔target feedback loop.
      @syncing = false

      # `style_to_attr` memos for the per-frame render, one per style slot read
      # there (the two trough halves, the thumb, and the two stepper arrows):
      # the bar redraws every frame with unchanged styles, so each derivation
      # is skipped until that slot's resolved style is mutated or swapped. The
      # `resolve_slot` fallbacks return varying *objects* only when the styling
      # changes, which the identity half of the gate catches; each stepper memo
      # spans its horizontal/vertical arms the same way (only one arm runs per
      # frame, and an orientation flip swaps the fetched style object).
      @sub_page_attr_memo = Style::AttrMemo.new
      @add_page_attr_memo = Style::AttrMemo.new
      @thumb_attr_memo = Style::AttrMemo.new
      @dec_attr_memo = Style::AttrMemo.new
      @inc_attr_memo = Style::AttrMemo.new

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
        single_step : Int32? = nil,
        @page_step = 1,
        @orientation = @orientation,
        @thumb_char = nil,
        @trough_char = nil,
        @stepper_buttons = false,
        @show_trough = true,
        **input,
      )
        # `single_step:` is the Qt-parity spelling and the only one accepted.
        @single_step = single_step || 1

        super **input

        # Never store an inverted range; it would leave `#value` stuck after `clamp`.
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress

        on(Crysterm::Event::Mouse) do |e|
          # Wheel steps the value, inverted: wheel-up scrolls toward the top, i.e.
          # a smaller value. A release commits an untracked drag.
          next unless drag_gesture? e, wheel_invert: true

          # Clip-aware painted-track resolution, shared with `Slider`/
          # `ProgressBar` via `Mixin::TrackGeometry#pointer_track`. `pad:
          # false`: the bar paints its track into the border-only interior
          # (`with_inner_coords`), so padding stays out of the pointer math
          # too.
          raw, inner = pointer_track e, pad: false
          steppers = stepper_buttons? && inner >= 3
          # A click on a stepper-button cell steps by `#single_step` instead of seeking.
          if steppers && e.action.down? && (raw <= 0 || raw >= inner - 1)
            raw <= 0 ? step_down : step_up
            e.accept
            update!
            next
          end
          # Seek within the trough, which starts one cell in when steppers show.
          pos = raw - (steppers ? 1 : 0)
          span = (steppers ? inner - 2 : inner) - 1
          next if span <= 0
          # `pos` is clamped: a scroll bar sizes a thumb and must not seek past
          # the ends.
          v = (value_at pos.clamp(0, span), span).clamp(@minimum, @maximum)
          self.slider_position = v
          # `Event::SliderMoved` on every drag motion, independent of
          # `#tracking?` — `#slider_position=` already emits `ValueChanged`
          # per move when tracking, so this never duplicates that.
          emit Crysterm::Event::SliderMoved, v
          # Capture the mouse so a drag that leaves the bar's (often 1-column)
          # bounds keeps delivering motion/release here instead of freezing the
          # thumb, and so an untracked drag's pending `@slider_position` can't
          # strand uncommitted on a release off the bar. Idempotent.
          window?.try &.capture_mouse(self)
          e.accept
          update!
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
        update!
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
            {@dec_attr_memo.fetch(resolve_slot(base.left_arrow, button, base)), left_arrow_char}
          else
            {@dec_attr_memo.fetch(resolve_slot(base.up_arrow, button, base)), up_arrow_char}
          end
        else
          button = resolve_slot(base.add_line, base, base)
          if @orientation.horizontal?
            {@inc_attr_memo.fetch(resolve_slot(base.right_arrow, button, base)), right_arrow_char}
          else
            {@inc_attr_memo.fetch(resolve_slot(base.down_arrow, button, base)), down_arrow_char}
          end
        end
      end

      def paint(*, with_children = true)
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
          sub_page_attr = @sub_page_attr_memo.fetch(resolve_slot(base.sub_page, base.track, base))
          add_page_attr = @add_page_attr_memo.fetch(resolve_slot(base.add_page, base.track, base))
          thumb_attr = @thumb_attr_memo.fetch(base.indicator)

          # With the trough hidden, only the thumb is drawn; a space keeps the
          # reserved column empty rather than glyph-filled. Both glyphs hoisted
          # out of the per-cell loop: registry resolution walks to the window.
          trough_ch = show_trough? ? trough_char : ' '
          thumb_ch = thumb_char

          # The track is three (or five, with steppers) contiguous zones along
          # the main axis — `thumb_offset`/`thumb_size` clamp so the thumb never
          # overlaps or escapes `[trough_lo, trough_hi)` — so each zone is one
          # batched `fill_region` run instead of a per-cell call.
          if steppers
            dec_attr, dec_ch = stepper_cell true, base
            paint_cross_span horizontal, main_lo, main_lo + 1, xi, xl, yi, yl, dec_attr, dec_ch
            inc_attr, inc_ch = stepper_cell false, base
            paint_cross_span horizontal, main_hi - 1, main_hi, xi, xl, yi, yl, inc_attr, inc_ch
          end
          paint_cross_span horizontal, trough_lo, thumb_lo, xi, xl, yi, yl, sub_page_attr, trough_ch
          paint_cross_span horizontal, thumb_lo, thumb_hi, xi, xl, yi, yl, thumb_attr, thumb_ch
          paint_cross_span horizontal, thumb_hi, trough_hi, xi, xl, yi, yl, add_page_attr, trough_ch
        end
      end

      # Fills the cross-axis extent across main-axis span `[lo, hi)` with
      # *attr*/*ch*: for a vertical bar `[lo, hi)` is a row range (fill columns
      # `xi...xl` for each); for a horizontal bar it's a column range (fill rows
      # `yi...yl` for each). A contiguous run, so it goes through the batched
      # `fill_region`, not a per-cell loop. A no-op when `lo >= hi`.
      private def paint_cross_span(horizontal, lo, hi, xi, xl, yi, yl, attr, ch) : Nil
        if horizontal
          window.fill_region attr, ch, lo, hi, yi, yl
        else
          window.fill_region attr, ch, xi, xl, lo, hi
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
