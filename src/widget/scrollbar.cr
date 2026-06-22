require "./input"
require "../mixin/ranged_value"

module Crysterm
  class Widget
    # Standalone scroll bar, modeled after Qt's `QScrollBar`.
    #
    # On its own it is a draggable position control: an integer `#value` in
    # `[#minimum, #maximum]` with a proportional thumb sized from `#page_step`,
    # moved by dragging/clicking the trough, the arrow keys, Page Up/Down, or the
    # wheel. It emits `Event::ValueChange` on every change.
    #
    # More usefully, it **binds to** a scrollable widget via `#attach`: the bar
    # then reflects and drives that widget's scroll position through the existing
    # scroll machinery (`Widget#scroll_to`/`#child_base`/`Event::Scroll` from
    # `widget_scrolling.cr`), rather than reimplementing it. Crysterm's other
    # scrollable widgets keep their built-in render-time scrollbar indicator;
    # this widget is for when you want a *separate*, interactive bar (e.g. beside
    # a `Box`, or shared by a custom layout).
    #
    # ```
    # box = Widget::ScrollableBox.new parent: screen, top: 0, left: 0, width: 40, height: 10, content: long_text
    # sb = Widget::ScrollBar.new parent: screen, top: 0, left: 40, width: 1, height: 10
    # sb.attach box
    # ```
    class ScrollBar < Input
      # Range/value behavior (`#minimum`/`#maximum`/`#value`/`#step`,
      # `#increment`/`#decrement`, `Event::ValueChange`).
      include Mixin::RangedValue

      # A scroll bar draws a fixed-size trough; it must not shrink to its content.
      @resizable = false

      property orientation : Tput::Orientation = :vertical

      # Size of one "page" (Qt's `pageStep`): the visible span, which also sizes
      # the thumb. Page Up/Down move by this much.
      property page_step : Int32 = 1

      # Glyphs for the thumb and the trough.
      property thumb_char : Char = '█'
      property trough_char : Char = '░'

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
        **input,
      )
        super **input

        @value = (value || @minimum).clamp(@minimum, @maximum)

        handle Crysterm::Event::KeyPress

        on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_up?
            decrement
            e.accept
            request_render
            next
          elsif e.action.wheel_down?
            increment
            e.accept
            request_render
            next
          end

          next unless e.action.down? || (e.action.move? && !e.button.none?)
          if @orientation.horizontal?
            pos = e.x - aleft - ileft
            span = awidth - iwidth - 1
          else
            pos = e.y - atop - itop
            span = aheight - iheight - 1
          end
          next if span <= 0
          self.value = @minimum + (pos * value_span / span.to_f).round.to_i
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

      # Recomputes the range/page from the target's geometry and mirrors its
      # current scroll offset onto `#value` (without driving the target back).
      def sync_from_target : Nil
        t = @target
        return unless t
        visible = @orientation.horizontal? ? (t.awidth - t.iwidth) : (t.aheight - t.iheight)
        total = t.get_scroll_height
        @minimum = 0
        @maximum = Math.max(0, total - visible)
        @page_step = Math.max(1, visible)
        @syncing = true
        # Mirror the engine's combined scroll position (`child_base + child_offset`,
        # what `scroll_to` also targets) so the two stay consistent.
        self.value = t.get_scroll.clamp(@minimum, @maximum)
        @syncing = false
        request_render
      rescue
        # Target not laid out yet.
      end

      # Drives the bound target when the bar moves (mixin hook).
      protected def on_value_changed
        return if @syncing
        @target.try &.scroll_to(@value)
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
        ((@value - @minimum) * room / value_span.to_f).round.to_i.clamp(0, Math.max(0, room))
      end

      def render
        with_inner_coords do |xi, xl, yi, yl|
          trough_attr = sattr style
          screen.fill_region trough_attr, @trough_char, xi, xl, yi, yl

          thumb_attr = sattr style.bar
          if @orientation.horizontal?
            avail = xl - xi
            sz = thumb_size avail
            off = thumb_offset avail
            (yi...yl).each do |y|
              screen.lines[y]?.try do |line|
                (0...sz).each do |k|
                  line[xi + off + k]?.try do |cell|
                    cell.char = @thumb_char
                    cell.attr = thumb_attr
                  end
                end
                line.dirty = true
              end
            end
          else
            avail = yl - yi
            sz = thumb_size avail
            off = thumb_offset avail
            (0...sz).each do |k|
              screen.lines[yi + off + k]?.try do |line|
                (xi...xl).each do |x|
                  line[x]?.try do |cell|
                    cell.char = @thumb_char
                    cell.attr = thumb_attr
                  end
                end
                line.dirty = true
              end
            end
          end
        end
      end

      def on_keypress(e)
        k = e.key
        case
        when k == Tput::Key::Up || k == Tput::Key::Left
          decrement
        when k == Tput::Key::Down || k == Tput::Key::Right
          increment
        when k == Tput::Key::PageUp
          decrement @page_step
        when k == Tput::Key::PageDown
          increment @page_step
        when k == Tput::Key::Home
          self.value = @minimum
        when k == Tput::Key::End
          self.value = @maximum
        else
          return
        end
        e.accept
        request_render
      end

      def destroy
        detach
        super
      end
    end
  end
end
