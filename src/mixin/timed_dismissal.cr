module Crysterm
  module Mixin
    # Generation-guarded timed dismissal. A dismissal fiber armed for one item
    # captures the then-current generation; once a newer item supersedes it the
    # captured value no longer matches, so a stale timer can't dismiss a later
    # item early.
    #
    # The including widget bumps via `#bump_dismiss_gen` (on each present, and
    # again on teardown to invalidate a pending timer), arms a timer with
    # `#after`, and guards its on-expire action with `#dismiss_current?`.
    module TimedDismissal
      @dismiss_gen = 0
      @dismiss_timer : Timer?

      # Bumps the generation and returns the new value — to be captured by a
      # freshly-armed dismissal timer, or called bare (e.g. on teardown) to
      # invalidate any still-pending timer. Also cancels the pending timer
      # outright — the generation guard alone only neutralizes its block, and
      # would leave the superseded timer's fiber sleeping toward a no-op.
      protected def bump_dismiss_gen : Int32
        @dismiss_timer.try &.stop
        @dismiss_timer = nil
        @dismiss_gen += 1
      end

      # Whether *gen* is still current, i.e. no newer item has superseded it.
      protected def dismiss_current?(gen : Int32) : Bool
        gen == @dismiss_gen
      end

      # Arms a one-shot that runs *block* after *span* — a cancellable
      # `Timer.single_shot`, the same shape `Window#after` uses (minus its
      # render; dismissal blocks request their own). Returns the `Timer`, and
      # keeps it so `#bump_dismiss_gen` can cancel it early.
      protected def after(span : Time::Span, &block : ->) : Timer
        @dismiss_timer = Timer.single_shot(span, &block)
      end
    end
  end
end
