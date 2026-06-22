require "./box"

module Crysterm
  class Widget
    # Centered startup overlay, modeled after Qt's `QSplashScreen`.
    #
    # Shows a centered (by default) frame while an app initializes, optionally
    # holding an animated `#content` widget (e.g. an `Effect`, `Gradient`,
    # `Marquee`, `Image`, or `Loading` spinner — they animate themselves off the
    # usual `Timer`/`animate:` machinery) and a bottom status line updated with
    # `#show_message`. Dismiss it with `#finish` (or `#finish_after`), revealing
    # the UI behind it; `#finish` emits `Event::Complete`.
    #
    # ```
    # splash = Widget::SplashScreen.new parent: s, width: 50, height: 14,
    #   content: Widget::Effect::Matrix.new(animate: true), style: Style.new(border: true)
    # splash.show_message "Loading…"
    # splash.finish_after 2.seconds
    # ```
    class SplashScreen < Box
      # A splash is a fixed-size overlay: honor the given `width`/`height` rather
      # than shrinking to content (which would also break the centering math).
      @resizable = false

      # The (often animated) content widget. Named `content_widget` because
      # `@content` is the base `Widget`'s textual content.
      getter content_widget : Widget?
      getter! message_box : Box

      def initialize(content : Widget? = nil, message_height = 1, **box)
        super **box

        # Center on the parent/screen unless the caller positioned it explicitly.
        self.top = "center" if top.nil?
        self.left = "center" if left.nil?

        @message_box = Box.new(
          parent: self, bottom: 0, left: 0, right: 0, height: message_height,
          align: :center, parse_tags: true,
        )

        content.try { |c| self.content_widget = c }
        front!
      end

      # Sets (replacing any previous) the splash's content widget, filling the
      # area above the message line.
      def content_widget=(widget : Widget) : Widget
        @content_widget.try &.remove_from_parent
        @content_widget = widget
        widget.top = 0
        widget.left = 0
        widget.right = 0
        widget.bottom = message_box.height.as?(Int) || 1
        append widget
        request_render
        widget
      end

      # Updates the bottom status line (Qt's `showMessage`).
      def show_message(text : String) : Nil
        message_box.set_content text
        request_render
      end

      # Dismisses the splash: emits `Event::Complete`, detaches and destroys it.
      def finish : Nil
        emit ::Crysterm::Event::Complete
        screen?.try &.remove self
        destroy
      end

      # Dismisses the splash after *span* (on the render fiber, so it's safe to
      # call from anywhere).
      def finish_after(span : Time::Span) : Nil
        spawn do
          sleep span
          screen?.try &.post { finish }
        end
      end
    end
  end
end
