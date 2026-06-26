require "./box"

module Crysterm
  class Widget
    # Centered startup overlay, modeled after Qt's `QSplashScreen`.
    #
    # Shows a centered (by default) frame while an app initializes, optionally
    # holding an animated `#content` widget (e.g. an `Effect`, `Gradient`,
    # `Marquee`, `Media`, or `Loading` spinner — they animate themselves off the
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
    #
    # <!-- widget-examples:capture v1 -->
    # ![SplashScreen screenshot](../../examples/widget/splash_screen/splash_screen-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class SplashScreen < Box
      # A splash is a fixed-size overlay: honor the given `width`/`height` rather
      # than shrinking to content (which would also break the centering math).
      @resizable = false

      # An overlay: at the unstyled floor it carries a structural border so it
      # separates from the content behind it (a theme can override or remove it;
      # see `Mixin::Style#floor_border?`).
      def floor_border? : Bool
        true
      end

      # Whether any input event dismisses the splash: a mouse click or wheel
      # *over it*, or any key press. Qt's `QSplashScreen` closes itself on a
      # mouse press (`mousePressEvent` → `hide`), so this defaults to `true`;
      # set it to `false` for a splash that only goes away via `#finish` /
      # `#finish_after` (e.g. a fixed-duration startup screen).
      property? dismiss_on_event : Bool = true

      # The (often animated) content widget. Named `content_widget` because
      # `@content` is the base `Widget`'s textual content.
      getter content_widget : Widget?
      getter! message_box : Box

      # The screen-level key listener (key presses are not positional, so we
      # watch the whole screen rather than just the splash).
      @ev_keys : Crysterm::Event::KeyPress::Wrapper?
      @finished = false

      def initialize(content : Widget? = nil, message_height = 1, dismiss_on_event : Bool? = nil, **box)
        super **box

        dismiss_on_event.try { |v| @dismiss_on_event = v }

        # Center on the parent/screen unless the caller positioned it explicitly.
        self.top = "center" if top.nil?
        self.left = "center" if left.nil?

        @message_box = Box.new(
          parent: self, bottom: 0, left: 0, right: 0, height: message_height,
          align: :center, parse_tags: true,
        )

        content.try { |c| self.content_widget = c }
        front!

        # A click/wheel over the splash, or any key press, dismisses it when
        # `dismiss_on_event?`. The flag is re-checked at event time, so it can be
        # toggled after construction.
        on(Crysterm::Event::Mouse) do |e|
          if dismiss_on_event? && (e.action.down? || e.action.wheel_up? || e.action.wheel_down?)
            e.accept
            finish
          end
        end
        @ev_keys = screen?.try &.on(Crysterm::Event::KeyPress) do
          finish if dismiss_on_event?
        end
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
      # Idempotent — safe to call more than once (e.g. a click and `finish_after`
      # racing).
      def finish : Nil
        return if @finished
        @finished = true
        # Capture the screen before detaching — `screen?` goes nil once removed.
        scr = screen?
        @ev_keys.try { |w| scr.try &.off Crysterm::Event::KeyPress, w }
        @ev_keys = nil
        emit ::Crysterm::Event::Complete
        scr.try &.remove self
        destroy
        # Repaint so the splash actually clears. `request_render` is useless here
        # (we're no longer on the screen) and the animation that had been driving
        # frames just stopped via `Event::Complete`, so without this the stale
        # splash frame would linger until the next unrelated event. Removing a
        # top-level child forces a full composite, so this one render is enough.
        scr.try &.render
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
