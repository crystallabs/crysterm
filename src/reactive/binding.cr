module Crysterm
  module Reactive
    # A live connection from one or more `Signal`s to a side effect (typically a
    # widget property assignment). Created by `Reactive.bind`.
    #
    # It holds one `Event::Changed` subscription per watched signal in a
    # `Subscriptions` bag (`src/subscription.cr`), plus a `Destroy` subscription
    # on the owner installed by `Reactive.bind`, so it tears down with the
    # widget. This is the **permanent-registration** model: the watched set is
    # fixed for the binding's life — the common TUI case. Dynamic dependency
    # sets are the Phase-2 re-tracking `Effect` (see `REACTIVE.md`).
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

      # A watched signal changed: run now, or defer to the flush when execution
      # must be deferred — an explicit `Reactive.batch` (so a burst of writes
      # runs this binding once) *or* an in-flight propagation wave (so a binding
      # watching `Computed`s runs once, after the wave settles, on a consistent
      # set of derived values rather than a glitched half-updated pair). Matches
      # `Effect#schedule`'s leaf branch; see `Reactive.deferring?`.
      protected def fire : Nil
        return if disposed?
        if Reactive.deferring?
          Reactive.enqueue self
        else
          run
        end
      end

      # Executes the side effect, then asks the owner's window to repaint. The
      # repaint request is coalescing (the render doorbell), so many bindings
      # firing in one turn still collapse into a single frame.
      def run : Nil
        return if disposed?
        @block.call
        @owner.window?.try &.schedule_render
      end

      # Cancels every subscription. Idempotent; installed on the owner's
      # `Destroy` by `Reactive.bind`, and safe to call again by hand.
      def dispose : Nil
        return if disposed?
        @disposed = true
        @subs.off
      end
    end
  end
end
