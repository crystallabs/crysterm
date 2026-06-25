module Crysterm
  class Widget
    module Effect
      # Shared self-animation lifecycle for effects that drive their own frame
      # loop. An including widget must be a `Widget` (the loop calls `screen`) and
      # define `#step` — advance the simulation and repaint one frame, *state and
      # paint only* (no `screen.render`, no `sleep`). This module supplies
      # `#start` / `#stop` / `#toggle` and the fiber loop that ties
      # `step` → `screen.render` → `sleep interval` together.
      #
      # `#step` is public by convention so an effect can also be advanced from an
      # external clock — several effects sharing one frame counter, with a single
      # `screen.render` then painting them all.
      #
      # `Effect::Direct`, `Effect::CopperBar`, `Effect::SineScroller`, and
      # `Effect::Spray` all include this. A finite effect (like a non-looping
      # `Spray`) signals the end of its run through the `#done?` / `#on_done`
      # hooks; an endless one leaves them at their defaults and runs until
      # `#stop`.
      module Animated
        # Delay between frames.
        property interval : Time::Span = 0.07.seconds

        # The frame clock; non-nil while running. The loop lives in `Animation`.
        @animation : Animation?

        # Whether the effect is currently animating.
        def running? : Bool
          @animation.try(&.running?) || false
        end

        # Advance the simulation and repaint one frame (state + paint only — no
        # render, no sleep). Defined by the including effect.
        abstract def step

        # Hook re-checked after each painted frame: `true` once a *finite* effect
        # has finished, ending the run. Endless effects never finish and run
        # until `#stop` — the default.
        protected def done? : Bool
          false
        end

        # Hook run exactly once, right after `#done?` first reports `true` and
        # just before the loop exits. Default does nothing.
        protected def on_done
        end

        # Start the animation: an `Animation` that steps, renders, and sleeps
        # `interval`, until `#stop` (or, for a finite effect, until `#done?`).
        # A no-op if already running.
        def start
          return if running?
          @animation = Animation.new(@interval) do
            step
            request_render
            if done?
              # End on this frame (so the final state is shown), then notify —
              # `on_done` fires only on a *natural* finish, not an external `#stop`.
              @animation.try &.stop
              on_done
            end
          end
          @animation.try &.start
        end

        # Stop the animation. The fiber exits on its next iteration.
        def stop
          @animation.try &.stop
        end

        def toggle
          running? ? stop : start
        end
      end
    end
  end
end
