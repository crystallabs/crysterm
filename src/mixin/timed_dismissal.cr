module Crysterm
  module Mixin
    # Generation-guarded timed dismissal. A dismissal fiber armed for one item
    # captures the then-current generation; once a newer item supersedes it the
    # captured value no longer matches, so a stale timer can't dismiss a later
    # item early.
    #
    # The including widget bumps via `#bump_dismiss_gen` (on each present, and
    # again on teardown to invalidate a pending fiber), arms a timer with
    # `#after`, and guards its on-expire action with `#dismiss_current?`.
    module TimedDismissal
      @dismiss_gen = 0

      # Bumps the generation and returns the new value — to be captured by a
      # freshly-armed dismissal fiber, or called bare (e.g. on teardown) to
      # invalidate any still-pending fiber.
      protected def bump_dismiss_gen : Int32
        @dismiss_gen += 1
      end

      # Whether *gen* is still current, i.e. no newer item has superseded it.
      protected def dismiss_current?(gen : Int32) : Bool
        gen == @dismiss_gen
      end

      # Arms a fiber that sleeps *span*, then runs *block*.
      protected def after(span : Time::Span, &block : ->) : Nil
        spawn do
          sleep span
          block.call
        end
      end
    end
  end
end
