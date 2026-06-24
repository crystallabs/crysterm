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
    # bar = Widget::StatusBar.new parent: screen, bottom: 0, left: 0, width: "100%", height: 1
    # bar.add_permanent "UTF-8"
    # bar.add_permanent "Ln 1, Col 1"
    # bar.show_message "Saved", 2.seconds
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![StatusBar screenshot](../../examples/widget/status_bar/status_bar-capture.png)
    # <!-- /widget-examples:capture -->
    class StatusBar < Box
      # The current temporary (left-aligned) message.
      getter message : String = ""

      # The permanent (right-aligned) sections, in insertion order; rendered
      # right-to-left so the first added sits left-most of the right group.
      getter permanent = [] of String

      # Bumped on each `#show_message` so a pending timeout only clears *its own*
      # message, not a newer one.
      @message_gen = 0

      def initialize(**box)
        super **box
        # Colors come from the CSS theme (`StatusBar { ... }`).
      end

      # Shows *text* as the temporary message. With *timeout*, the message clears
      # itself after that span (unless replaced first); without, it stays until
      # the next `#show_message`/`#clear_message`.
      def show_message(text : String, timeout : Time::Span? = nil) : Nil
        @message = text
        @message_gen += 1
        request_render

        if timeout
          gen = @message_gen
          spawn do
            sleep timeout
            # Marshal back onto the render fiber; only clear if still current.
            screen?.try &.post do
              if @message_gen == gen
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
        @message_gen += 1
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
        request_render
      end

      # Removes all permanent sections.
      def clear_permanent : Nil
        @permanent.clear
        request_render
      end

      def render(with_children = true)
        set_content @message
        super
        draw_permanent
      end

      # Overlays the permanent sections, right-aligned, after the base render has
      # painted the background and the (left) message. Uses the freshly resolved
      # interior coordinates, so it never lags a frame behind a resize.
      private def draw_permanent : Nil
        return if @permanent.empty?
        with_inner_coords do |xi, xl, yi, _yl|
          text = @permanent.reverse.join " │ "
          start = Math.max(xi, xl - text.size)
          attr = sattr style
          screen.lines[yi]?.try do |line|
            text.each_char_with_index do |ch, i|
              x = start + i
              break if x >= xl
              line[x]?.try do |cell|
                cell.char = ch
                cell.attr = attr
              end
            end
            line.dirty = true
          end
        end
      end
    end
  end
end
