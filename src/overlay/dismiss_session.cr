module Crysterm
  # Cross-cutting helpers for floating overlays (drop-downs, pop-up menus,
  # completer lists): the shared *interaction* policy that every overlay owner
  # otherwise re-decided inline.
  module Overlay
    # Owns the "modal grab + click-away-to-dismiss" lifecycle for one open
    # overlay, as a plain value object rather than a mixin — so it serves all
    # three owner shapes uniformly: a widget owning a pop-up child
    # (`Mixin::Popup` → `ComboBox`/`DateEdit`), a widget that *is* its own pop-up
    # (`Menu`), and a non-widget owner (`Completer`, which attaches to a
    # `LineEdit` and therefore can't inherit any widget lifecycle).
    #
    # Before this, the grab/watcher/teardown triple was hand-rolled at four
    # sites, and the "released grab on destroy" bug class recurred because the
    # dismiss path and the destroy path each tore things down separately. Here a
    # single idempotent `#close` is what both paths call.
    #
    # The window is captured at construction and used for both grab and detach,
    # so teardown works even from `Detach`/`Destroy`, where the owner's
    # `window?` has already been nilled (the `window` vs `window?` hazard that
    # made hand-rolled teardowns leak).
    class DismissSession
      # The live outside-press watcher handle (nil while closed).
      @ev : ::Crysterm::Event::Mouse::Wrapper?
      @open = false

      # * *grab_owner* — the widget to take a modal window grab for, or `nil` for
      #   no grab (e.g. `Completer`, whose box must keep reacting to keystrokes).
      # * *inside* — predicate: does `(x, y)` count as "inside" this overlay? A
      #   press anywhere else dismisses it.
      # * the block — invoked once when a press lands outside.
      def initialize(@window : Window, *, @grab_owner : Widget?,
                     @inside : Proc(Int32, Int32, Bool), &@on_dismiss : -> Nil)
      end

      # Takes the modal grab (if an owner was given) and installs the
      # outside-press watcher. Idempotent: a second call while open is a no-op.
      def open : Nil
        return if @open
        @open = true
        if owner = @grab_owner
          @window.grab owner
        end
        cb = @on_dismiss
        @ev = @window.on_press_outside(@inside) { cb.call }
      end

      # Releases the grab and detaches the watcher. Idempotent, so it is safe to
      # call from both a normal dismiss and a destroy without double-freeing.
      def close : Nil
        return unless @open
        @open = false
        if owner = @grab_owner
          @window.ungrab owner
        end
        @ev.try { |w| @window.off ::Crysterm::Event::Mouse, w }
        @ev = nil
      end

      # Whether the grab/watcher are currently installed.
      def open? : Bool
        @open
      end
    end
  end
end
