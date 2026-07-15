module Crysterm
  # Cross-cutting interaction policy for floating overlays: drop-downs, pop-up
  # menus, completer lists.
  module Overlay
    # Owns the "modal grab + click-away-to-dismiss" lifecycle for one open
    # overlay. A plain value object rather than a mixin, so it serves every owner
    # shape uniformly: a widget owning a pop-up child, a widget that *is* its own
    # pop-up, and a non-widget owner that can inherit no widget lifecycle. Both
    # the dismiss path and the destroy path call the same idempotent `#close`.
    #
    # The window is captured at construction and used for both grab and detach,
    # so teardown works even from `Detach`/`Destroy`, where the owner's `window?`
    # has already been nilled.
    class DismissSession
      # The live outside-press watcher. Captures the window, so `#close` detaches
      # from the right emitter even after the owner detaches. Idle while closed.
      @watcher = ::Crysterm::Subscription.new
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
        inside = @inside
        @watcher.on(@window, ::Crysterm::Event::Mouse) do |e|
          cb.call if e.action.down? && !inside.call(e.x, e.y)
        end
      end

      # Releases the grab and detaches the watcher. Idempotent, so it is safe to
      # call from both a normal dismiss and a destroy without double-freeing.
      def close : Nil
        return unless @open
        @open = false
        if owner = @grab_owner
          @window.ungrab owner
        end
        @watcher.off
      end

      # Whether the grab/watcher are currently installed.
      def open? : Bool
        @open
      end
    end
  end
end
