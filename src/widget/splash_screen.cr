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
    # ![SplashScreen screenshot](../../tests/widget/splash_screen/splash_screen.5s.apng)
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
      # `#finish_after` (e.g. a fixed-duration startup window).
      property? dismiss_on_event : Bool = true

      # The (often animated) content widget. Named `content_widget` because
      # `@content` is the base `Widget`'s textual content.
      getter content_widget : Widget?
      getter! message_box : Box

      # The window-level key listener (key presses are not positional, so we
      # watch the whole window rather than just the splash). A `Subscription`
      # captures the window it installed on, so teardown reaches the right one
      # even on `Detach`, where `window?` may already have moved on.
      @ev_keys = Crysterm::Subscription.new
      @finished = false

      def initialize(content : Widget? = nil, message_height = 1, dismiss_on_event : Bool? = nil, **box)
        super **box

        dismiss_on_event.try { |v| @dismiss_on_event = v }

        # Center on the parent/window unless the caller positioned it explicitly.
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
        # Wire the key-dismiss accelerator with the splash's attach lifecycle so
        # it works even when the splash is constructed detached (no `parent:`/
        # `window:`) and appended later — at construction `window?` would be nil,
        # so a one-shot install here would silently never fire for keys. Install
        # now too, in case it's already on a window.
        on(Crysterm::Event::Attach) { install_key_dismiss }
        # `Widget#remove` nulls `parent`/`window` before `Window#detach` emits
        # `Event::Detach`, so the previous window comes via the payload.
        on(Crysterm::Event::Detach) { remove_key_dismiss }
        install_key_dismiss
      end

      # Installs the window-level key-press accelerator (idempotent).
      private def install_key_dismiss : Nil
        return if @ev_keys.active?
        if w = window?
          @ev_keys.on(w, Crysterm::Event::KeyPress) do
            finish if dismiss_on_event?
          end
        end
      end

      # Withdraws the key-press accelerator (from whichever window it was
      # installed on — the `Subscription` captured it, so this works from
      # `Detach` too, without being handed the leaving window).
      private def remove_key_dismiss : Nil
        @ev_keys.off
      end

      # Sets (replacing any previous) the splash's content widget, filling the
      # area above the message line.
      def content_widget=(widget : Widget) : Widget
        @content_widget = replace_content_child @content_widget, widget,
          bottom: message_box.height.as?(Int) || 1
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
        # Capture the window before detaching — `window?` goes nil once removed.
        scr = window?
        remove_key_dismiss
        emit ::Crysterm::Event::Complete
        scr.try &.remove self
        destroy
        # Repaint so the splash clears immediately; `request_render` is a no-op
        # once detached. Removing a top-level child forces a full composite, so
        # this one render suffices.
        scr.try &.render
      end

      # Dismisses the splash after *span* (on the render fiber, so it's safe to
      # call from anywhere).
      def finish_after(span : Time::Span) : Nil
        spawn do
          sleep span
          window?.try &.post { finish }
        end
      end

      # Torn down without a `#finish` (window/app teardown): drop the key-press
      # accelerator so it can't linger on the window referencing a dead splash.
      # (A normal `#finish` already removed it, and the `Detach` handler covers a
      # detach-then-destroy; this covers a direct destroy while still attached.)
      def destroy
        remove_key_dismiss
        super
      end
    end
  end
end
