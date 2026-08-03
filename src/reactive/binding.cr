module Crysterm
  module Reactive
    # A live connection from one or more `Signal`s to a side effect (typically a
    # widget property assignment). Created by `Reactive.bind`.
    #
    # It holds one `Event::Changed` subscription per watched signal, plus a
    # `Destroy` subscription on the owner, so it tears down with the widget. This
    # is the **permanent-registration** model: the watched set is fixed for the
    # binding's life. Dynamic dependency sets are the re-tracking `Effect`.
    class Binding
      include Deferrable

      @subs = ::Crysterm::Subscriptions.new
      getter? disposed = false

      def initialize(@owner : ::Crysterm::Widget, @block : ->)
      end

      # Subscribes this binding to *signal*'s changes.
      def watch(signal : SignalBase) : Nil
        @subs.on(signal, ::Crysterm::Event::Changed) { fire }
      end

      # Hooks auto-dispose to the owner's `Event::Destroy`, routed through
      # `@subs` so `dispose` also unhooks it — a binding disposed early by hand
      # must not leave a dead handler (pinning this binding and everything its
      # block captured) on the long-lived owner. Called by `Reactive.bind`.
      protected def attach_auto_dispose : Nil
        @subs.auto_dispose(@owner) { dispose }
      end

      # A watched signal changed: run now, or defer to the flush under an explicit
      # `Reactive.batch` (so a burst of writes runs this binding once) or an
      # in-flight propagation wave (so a binding watching `Computed`s runs once,
      # after the wave settles, on a consistent set of derived values).
      protected def fire : Nil
        return if disposed?
        if Reactive.deferring?
          Reactive.enqueue self
        else
          run
        end
      end

      # Executes the side effect, then asks the owner to repaint. The request is
      # coalescing (it rings the render doorbell), so many bindings firing in one
      # turn still collapse into a single frame.
      #
      # It goes through `Widget#request_render` — which marks the owner damaged
      # *and* rings the doorbell — rather than the bare doorbell, because the
      # block's mutation may be one damage tracking cannot observe (an in-place
      # `Style` write, a plain ivar the widget renders from). A doorbell-only
      # frame would then find an empty dirty set, take the selective path's
      # "nothing changed" shortcut and carry the previous frame's buffer over
      # verbatim, dropping the change entirely (it would render only with damage
      # tracking off). Same pairing as `reactive_property`'s `mark_dirty` +
      # `update`.
      #
      # The block runs untracked: bindings never legitimately track (the watched
      # set is fixed via `#watch`), and the bind-time initial run can happen
      # while an enclosing `Effect` is the active scope — without suspension its
      # signal reads would graft this binding's fixed dependency set onto that
      # effect's dynamic one, re-running (and re-binding) it on every change.
      def run : Nil
        return if disposed?
        Reactive.untracked { @block.call }
        @owner.request_render
      end

      # Cancels every subscription. Idempotent.
      def dispose : Nil
        return if disposed?
        @disposed = true
        @subs.off
      end
    end
  end
end
