module Crysterm
  module Mixin
    # Shared lifecycle for a widget that owns a floating pop-up *child* shown next
    # to it — a drop-down list, a calendar, … (`Widget::ComboBox`,
    # `Widget::DateEdit`). Centralizes the open flag, showing/raising/focusing
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
      # The grab + outside-press-watcher lifecycle, delegated to a shared
      # `Overlay::DismissSession` (also used by `Completer`/`Menu`) instead of
      # hand-rolled `grab`/`on_press_outside`/`off` bookkeeping. The `@open` flag
      # and `focus_popup:` focus policy stay here (they're the owner's business).
      @dismiss : ::Crysterm::Overlay::DismissSession?

      # NOTE: the including widget must define `#popup_widget : Widget?` — its
      # current pop-up (or `nil`). Left duck-typed rather than `abstract def`,
      # which tripped a codegen crash when included by more than one widget.

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
        # Modal grab + "click-away to dismiss" (a press outside this widget *and*
        # its pop-up closes it), owned by a fresh session bound to the current
        # window. Recreated each open so a re-attach to a different window works.
        s = ::Crysterm::Overlay::DismissSession.new(
          window, grab_owner: self,
          inside: ->(x : Int32, y : Int32) { grab_contains?(x, y) }) { close }
        s.open
        @dismiss = s
        request_render
      end

      # Hides the pop-up and releases the grab and outside-click watcher. Returns
      # whether it had been open, so `#close` can early-return when it wasn't.
      protected def teardown_popup : Bool
        return false unless @open
        @open = false
        @dismiss.try &.close
        popup_widget.try &.hide
        request_render
        true
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
        # Release the modal grab + watcher if destroyed while still open. The
        # session's `#close` is idempotent and holds its own window reference, so
        # it works even though destroy can run without a prior `#close` (which
        # would otherwise leave the dead widget lingering in `@grabs`, keeping
        # `Window#grabbing?` true and routing presses to a dead widget).
        @open = false
        @dismiss.try &.close
        ::Crysterm::Widget.destroy_satellite popup_widget
      end
    end
  end
end
