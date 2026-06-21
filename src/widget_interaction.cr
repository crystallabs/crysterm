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
        # A widget that listens for drops is a drop target and must be
        # hit-testable so an in-flight drag can target it.
        handlers(Crysterm::Event::DragEnter).any? ||
        handlers(Crysterm::Event::DragOver).any? ||
        handlers(Crysterm::Event::DragLeave).any? ||
        handlers(Crysterm::Event::Drop).any? ||
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
      draggable ? enable_drag : disable_drag
    end

    # Grab offset captured at `DragStart`, so a reposition keeps the grabbed
    # point under the pointer rather than snapping the corner to it.
    @_drag_dx = 0
    @_drag_dy = 0

    # Whether the default reposition handlers have been installed (so toggling
    # `draggable` repeatedly doesn't stack duplicate handlers).
    @_drag_reposition_installed = false

    # Marks the widget as a drag source. By default also installs the
    # **reposition** behavior: while dragged (by mouse or keyboard) the widget
    # follows the anchor by editing its own `left`/`top` (the "self-move" flavor,
    # matching Blessed's `enableDrag`).
    #
    # Pass `reposition: false` for a **data-transfer** source that should stay
    # put and instead hand a payload to a drop target — fill `data` in your own
    # `Event::DragStart` handler and react in `Event::DragEnd`/`Event::Drop`.
    def enable_drag(reposition = true) : Bool
      @draggable = true

      if reposition && !@_drag_reposition_installed
        @_drag_reposition_installed = true

        on(Crysterm::Event::DragStart) do |e|
          @_drag_dx = e.x - aleft
          @_drag_dy = e.y - atop
        end

        on(Crysterm::Event::Drag) do |e|
          self.left = (e.x - @_drag_dx).clamp(0, drag_max_left)
          self.top = (e.y - @_drag_dy).clamp(0, drag_max_top)
        end
      end

      @draggable
    end

    # Largest `left`/`top` that keeps the widget within its parent (or the
    # screen, when parented directly to it).
    private def drag_max_left : Int32
      bound = parent.try(&.awidth) || screen.awidth
      {bound - awidth, 0}.max
    end

    private def drag_max_top : Int32
      bound = parent.try(&.aheight) || screen.aheight
      {bound - aheight, 0}.max
    end

    # Whether this widget self-moves while dragged (the default reposition
    # behavior is installed). A transfer-only source (`enable_drag reposition:
    # false`) returns false, which the engine uses to decide whether to float a
    # drag "ghost".
    def drag_repositions? : Bool
      @_drag_reposition_installed
    end

    def disable_drag : Bool
      @draggable = false
    end

    # :nodoc:
    # no-op in this place
    def _update_cursor(arg)
    end
    # end
  end
end
