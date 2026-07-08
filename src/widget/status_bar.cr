require "./box"

module Crysterm
  class Widget
    # Horizontal status bar, modeled after Qt's `QStatusBar`.
    #
    # Shows a temporary `#message` on the left (set with `#show_message`,
    # optionally auto-clearing after a timeout) and any number of *permanent*
    # sections right-aligned (added with `#add_permanent`). Typically one row tall
    # at the bottom of a window.
    #
    # ```
    # bar = Widget::StatusBar.new parent: window, bottom: 0, left: 0, width: "100%", height: 1
    # bar.add_permanent "UTF-8"
    # bar.add_permanent "Ln 1, Col 1"
    # bar.show_message "Saved", 2.seconds
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![StatusBar screenshot](../../tests/widget/status_bar/status_bar.5s.apng)
    # <!-- /widget-examples:capture -->
    class StatusBar < Box
      # Generation-guarded timed dismissal: a pending `#show_message` timeout only
      # clears *its own* message, not a newer one (see `Mixin::TimedDismissal`).
      include ::Crysterm::Mixin::TimedDismissal

      # The current temporary (left-aligned) message.
      getter message : String = ""

      # Permanent (right-aligned) sections, in insertion order; the first added
      # sits left-most of the right group (Qt's `addPermanentWidget` order).
      # Mutate via `#add_permanent`/`#clear_permanent` so the cached render
      # string (`@permanent_text`) stays in sync.
      getter permanent = [] of String

      # Cached joined render string for `#permanent`, rebuilt only when the
      # sections change (rather than re-joining a reversed copy every frame).
      @permanent_text = ""

      # Cached left-truncated permanent string plus the `(avail, source)` it was
      # built for, so a steady-state overflowing status bar doesn't slice a fresh
      # substring every frame.
      @_trunc : String = ""
      @_trunc_key : Tuple(Int32, String)?

      def initialize(**box)
        super **box
        # Colors come from the CSS theme (`StatusBar { ... }`).
      end

      # Shows *text* as the temporary message. With *timeout*, the message clears
      # itself after that span (unless replaced first); without, it stays until
      # the next `#show_message`/`#clear_message`.
      def show_message(text : String, timeout : Time::Span? = nil) : Nil
        @message = text
        gen = bump_dismiss_gen
        request_render

        if timeout
          after timeout do
            # Marshal back onto the render fiber; only clear if still current.
            window?.try &.post do
              if dismiss_current?(gen)
                @message = ""
                request_render
              end
            end
          end
        end
      end

      # Clears the temporary message immediately (Qt's `clearMessage`).
      def clear_message : Nil
        @message = ""
        bump_dismiss_gen
        request_render
      end

      # :ditto: assignment form.
      def message=(text : String) : String
        show_message text
        text
      end

      # Appends a permanent right-aligned section (Qt's `addPermanentWidget`,
      # specialized to a text label).
      def add_permanent(text : String) : Nil
        @permanent << text
        @permanent_text = @permanent.join " #{glyph(Glyphs::Role::LineVertical)} "
        request_render
      end

      # Removes all permanent sections.
      def clear_permanent : Nil
        @permanent.clear
        @permanent_text = ""
        request_render
      end

      def render(with_children = true)
        set_content @message
        super
        draw_permanent
      end

      # Overlays the permanent sections, right-aligned, after the base render
      # paints the background and (left) message. Uses freshly resolved
      # interior coordinates, so it never lags a frame behind a resize.
      private def draw_permanent : Nil
        return if @permanent.empty?
        with_inner_coords do |xi, xl, yi, _yl|
          avail = xl - xi
          return if avail <= 0
          text = @permanent_text
          # Right-aligned: on overflow drop the *left* end so the tail (the most
          # recently added sections) stays visible, rather than truncating the
          # right end by pinning the start to `xi`. The sliced tail is cached
          # against `(avail, source)` so an overflowing bar doesn't re-slice each
          # frame.
          if text.size > avail
            key = {avail, text}
            if @_trunc_key != key
              @_trunc_key = key
              @_trunc = text[(text.size - avail)..]
            end
            text = @_trunc
          end
          draw_text_run yi, xl - text.size, text, xl, sattr(style)
        end
      end
    end
  end
end
