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

        # Frame loop; non-nil while running.
        @fiber : Fiber?
        protected property? running = false

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

        # Start the animation: spawns a fiber that steps, renders, and sleeps
        # `interval`, until `#stop` (or, for a finite effect, until `#done?`).
        # A no-op if already running.
        def start
          return if running?
          self.running = true
          @fiber = Fiber.new do
            loop do
              break unless running?
              step
              request_render
              if done?
                self.running = false
                on_done
                break
              end
              sleep @interval
            end
          end.enqueue
        end

        # Stop the animation. The fiber exits on its next iteration.
        def stop
          self.running = false
        end

        def toggle
          running? ? stop : start
        end
      end
    end
  end
end
