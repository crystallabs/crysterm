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
      # clears *its own* message, not a newer one.
      include ::Crysterm::Mixin::TimedDismissal

      # The current temporary (left-aligned) message.
      getter message : String = ""

      # Permanent (right-aligned) sections, in insertion order; the first added
      # sits left-most of the right group (Qt's `addPermanentWidget` order).
      @permanent = [] of String

      # A snapshot of the permanent sections. A copy, not the live array: the
      # render string is cached against the sections, so mutating them behind
      # the bar's back would paint stale text. Add and remove through
      # `#add_permanent`/`#clear_permanent`, which keep the cache honest.
      def permanent : Array(String)
        @permanent.dup
      end

      # Cached joined render string for `#permanent`, rebuilt only when the
      # sections change.
      @permanent_text = ""

      # Cached left-truncated permanent string plus the `(avail, source)` it was
      # built for, so a steady-state overflowing status bar doesn't slice a fresh
      # substring every frame.
      @_trunc : String = ""
      @_trunc_key : Tuple(Int32, String)?

      def initialize(**box)
        super **box
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
          # recently added sections) stays visible. The sliced tail is cached
          # against `(avail, source)` so an overflowing bar doesn't re-slice each
          # frame. All accounting is in display cells (`str_width`), not
          # codepoints, or wide (CJK/emoji) sections misplace the run.
          tw = str_width text
          if tw > avail
            key = {avail, text}
            if @_trunc_key != key
              @_trunc_key = key
              @_trunc = truncate_left text, avail
            end
            text = @_trunc
            tw = str_width text
          end
          draw_text_run yi, xl - tw, text, xl, style_to_attr(style)
        end
      end

      # Drops graphemes off the left of *text* until its display width fits
      # *avail* cells (never splitting a grapheme — dropping a straddling wide
      # char makes the result one cell narrower rather than corrupt).
      private def truncate_left(text : String, avail : Int32) : String
        drop = str_width(text) - avail
        start_byte = 0
        text.each_grapheme do |g|
          break if drop <= 0
          s = g.to_s
          drop -= str_width s
          start_byte += s.bytesize
        end
        text.byte_slice(start_byte)
      end
    end
  end
end
