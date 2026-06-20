module Crysterm
  class Widget
    # module Interaction

    property? interactive = false

    # Is element clickable?
    property? clickable = false

    # Whether this widget should receive mouse events by default.
    #
    # Out of the box (mirroring GUI toolkits), a widget is mouse-responsive if it
    # is interactive (`input?`/`keyable?`), `scrollable?` (so the wheel can scroll
    # it), `draggable?`, was explicitly marked `clickable?`, or already has a
    # `Click`/`Mouse` listener attached. This is what `Screen#widget_at` uses for
    # hit-testing, so e.g. a plain `Box` that the user later attaches an
    # `Event::Click` handler to automatically starts receiving clicks, with no
    # need to also set `clickable: true`.
    def wants_mouse?
      clickable? || input? || keyable? || scrollable? || draggable? ||
        handlers(Crysterm::Event::Click).any? ||
        handlers(Crysterm::Event::Mouse).any? ||
        # Hover events each have their own handler list (they subclass `Mouse`
        # but are emitted/registered separately), so check them explicitly —
        # otherwise a widget with only hover handlers would never be hit-tested.
        handlers(Crysterm::Event::MouseOver).any? ||
        handlers(Crysterm::Event::MouseMove).any? ||
        handlers(Crysterm::Event::MouseOut).any?
    end

    # Can element receive keyboard input? (Managed internally; use `input` for user-side setting)
    property? keyable = false

    # Is element draggable?
    property? draggable = false

    property? focus_on_click = true

    property? vi : Bool = false

    # Does it accept keyboard input?
    property? input = false

    # Is the widget disabled? While disabled it does not react to keyboard
    # input (see `Screen#_listen_keys`). Toggle via `state = WidgetState::Disabled`.
    def disabled?
      state.disabled?
    end

    # Should widget react to some pre-defined keys in it?
    property? keys : Bool = false

    property? ignore_keys : Bool = false

    # property? clickable = false

    # Puts current widget in focus
    def focus
      # XXX Prevents getting multiple `Event::Focus`s. Remains to be
      # seen whether that's good, or it should always happen, even
      # if someone calls `#focus` multiple times in a row.
      return if focused?
      screen.focus self
    end

    # Returns whether widget is currently in focus
    @[AlwaysInline]
    def focused?
      screen.focused == self
    end

    def set_hover(hover_text)
    end

    def remove_hover
    end

    # These read/write `@draggable` (the ivar declared by `property? draggable`
    # and set by the constructor). They previously used a separate `@_draggable`
    # ivar that the constructor never touched, so `Widget.new(draggable: true)`
    # left `draggable?` reporting false.
    def draggable?
      @draggable
    end

    def draggable=(draggable : Bool)
      draggable ? enable_drag(draggable) : disable_drag
    end

    def enable_drag(x)
      @draggable = true
    end

    def disable_drag
      @draggable = false
    end

    # :nodoc:
    # no-op in this place
    def _update_cursor(arg)
    end
    # end
  end
end
