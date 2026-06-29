module Crysterm
  module Mixin
    # Shared lifecycle for a widget that owns a floating pop-up *child* shown next
    # to it — a drop-down list, a calendar, … (`Widget::ComboBox`,
    # `Widget::DateEdit`). It centralizes the open flag, showing/raising/focusing
    # the pop-up, the modal input grab, the outside-click watcher that dismisses
    # it, the grab region, and teardown.
    #
    # The including widget:
    #   * defines `#popup_widget : Widget?` — its current pop-up (or `nil`);
    #   * defines `#close` — the dismiss path; the outside-click watcher calls it,
    #     and it should call `#teardown_popup` then do any widget-specific cleanup
    #     (e.g. refocusing itself);
    #   * builds and positions the pop-up, then calls `#show_popup`;
    #   * calls `#teardown_popup_on_destroy` from its own `#destroy`.
    #
    # (`Widget::Menu` deliberately does *not* use this: it is its own pop-up, with
    # a submenu chain rather than a single child, so it manages its own lifecycle.)
    module Popup
      @open = false
      @ev_outside : ::Crysterm::Event::Mouse::Wrapper?

      # NOTE: the including widget must define `#popup_widget : Widget?` — its
      # current pop-up (or `nil`). (Left as a duck-typed requirement rather than
      # an `abstract def`, which tripped a codegen crash when the module was
      # included by more than one widget.)

      # Whether the pop-up is open.
      def open? : Bool
        @open
      end

      # Shows *pop* as the modal pop-up: raises it, optionally focuses it, grabs
      # input (so other widgets stop reacting to the pointer), and installs the
      # outside-click watcher that calls `#close`. The caller positions *pop*
      # first. Pass `focus_popup: false` to keep focus on the owner (e.g. an
      # editable combo that keeps filtering as you type).
      protected def show_popup(pop : ::Crysterm::Widget, focus_popup : Bool = true) : Nil
        @open = true
        pop.show
        pop.front!
        pop.focus if focus_popup
        window.grab self
        # Shared "click-away to dismiss" (the same `Window#on_press_outside` used
        # by the pop-up menus and the `Completer` drop-down): a press outside this
        # widget *and* its pop-up closes it.
        @ev_outside ||= window.on_press_outside(->(x : Int32, y : Int32) { grab_contains?(x, y) }) { close }
        request_render
      end

      # Hides the pop-up and releases the grab and outside-click watcher. Returns
      # whether it had been open, so `#close` can early-return when it wasn't.
      protected def teardown_popup : Bool
        return false unless @open
        release_grab
        detach_outside_watcher
        popup_widget.try &.hide
        request_render
        true
      end

      # Marks the pop-up closed and releases the modal window grab. Both teardown
      # paths do this: unconditionally after the open-guard in `#teardown_popup`,
      # and under `if @open` in `#teardown_popup_on_destroy`.
      private def release_grab : Nil
        @open = false
        window?.try &.ungrab self
      end

      # Removes the outside-click watcher from the window (if installed) and
      # clears the stored handle. Both teardown paths (`#teardown_popup` and
      # `#teardown_popup_on_destroy`) detach it identically.
      private def detach_outside_watcher : Nil
        @ev_outside.try { |w| window?.try &.off ::Crysterm::Event::Mouse, w }
        @ev_outside = nil
      end

      # Modal grab region (see `Widget#grab_contains?`): this widget plus its
      # pop-up.
      def grab_contains?(x : Int32, y : Int32) : Bool
        return true if contains_point?(x, y)
        (pop = popup_widget) ? pop.contains_point?(x, y) : false
      end

      # Detaches + destroys the pop-up and removes the watcher. Call from the
      # including widget's `#destroy` (before `super`).
      protected def teardown_popup_on_destroy : Nil
        # Release the modal grab if we're destroyed while still open. `#close`
        # (the normal dismiss path) does this via `#teardown_popup`, but destroy
        # can run without a prior close — leaving the now-dead widget lingering in
        # the window's `@grabs`, which keeps `Window#grabbing?` true and routes
        # every later mouse press through `grab_contains?` on a destroyed widget.
        release_grab if @open
        detach_outside_watcher
        if pop = popup_widget
          window?.try &.remove pop
          pop.destroy
        end
      end
    end
  end
end
