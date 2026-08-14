require "../box"
require "../../colors"
require "../../mixin/visibility_paused_clock"

module Crysterm
  class Widget
    module Effect
      # Shared self-animation lifecycle for effects that drive their own frame
      # loop. An including widget must be a `Widget` (the loop calls `window`)
      # and define `#step` — advance the simulation and repaint one frame,
      # state and paint only (no `window.update`, no `sleep`). Supplies
      # `#start`/`#stop`/`#toggle` and the fiber loop tying
      # `step` -> `window.update` -> `sleep interval` together.
      #
      # `#step` is public so an effect can also be advanced from an external
      # clock — several effects sharing one frame counter, one `window.update`
      # painting them all.
      #
      # A finite effect (like a non-looping `Spray`) signals the end of its run
      # through the `#done?` / `#on_done` hooks; an endless one leaves them at
      # their defaults and runs until `#stop`.
      module Animated
        # Pause-while-invisible / resume-when-visible core, shared with
        # `Widget#pulse`.
        include ::Crysterm::Mixin::VisibilityPausedClock

        # Delay between frames.
        getter interval : Time::Span = 0.07.seconds

        # :ditto:
        # Forwarded to the running `FrameClock`, whose loop reads its own copy
        # live on every tick — so a cadence change (e.g. from a speed slider)
        # applies mid-run instead of silently waiting for the next `#start`.
        def interval=(value : Time::Span) : Time::Span
          @interval = value
          @animation.try &.interval = value
          value
        end

        # The frame clock; non-nil while running.
        @animation : FrameClock?

        # Whether the one-time `Event::Destroy` teardown hook (plus the
        # Hide/Detached pause and Show/Attached resume hooks) has been
        # installed (lazily, on first `#start`), so it isn't registered on
        # every start.
        @animation_hooks_installed = false

        # Set by `#pause_animation` when the clock is stopped for visibility
        # (as opposed to an explicit `#stop`), so the Show/Attached hook knows
        # to resume it — and so an explicit `#stop` (which clears this) isn't
        # silently undone by the next show.
        @animation_paused = false

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

        # Start the animation: an `FrameClock` that steps, renders, and sleeps
        # `interval`, until `#stop` (or, for a finite effect, until `#done?`).
        # A no-op if already running.
        def start
          return if running?
          # Stop the frame clock when the widget is destroyed, or the fiber keeps
          # ticking `step` + `update!` on the dead widget for the process
          # lifetime. Also stop it (instead) when the widget is hidden or
          # detached, or the fiber keeps ticking `step` + `update!`
          # forever on a widget that is never painted — a hidden widget's
          # `coords` is nil so `paint` never runs, and a detached-but-alive
          # widget's `update!` no-ops while the clock still burns CPU.
          # The pause leaves `@animation_paused` set, so the Show/Attached hook
          # resumes it on the first render after `show`/re-attach. `Event::Hide`
          # and `Event::Attached` both propagate to descendants (via
          # `emit_descendants`/subtree notification), covering effects nested
          # inside a hidden/reattached container. Installed once, on first
          # start.
          unless @animation_hooks_installed
            @animation_hooks_installed = true
            on(::Crysterm::Event::Destroy) { stop }
            on(::Crysterm::Event::Hide) { pause_animation }
            on(::Crysterm::Event::Detached) { pause_animation }
            on(::Crysterm::Event::Show) { resume_animation }
            on(::Crysterm::Event::Attached) { resume_animation }
          end
          @animation = FrameClock.new(@interval) do
            step
            update!
            if done?
              # End on this frame (so the final state is shown), then notify.
              # `on_done` fires only on natural finish, not an external `#stop`.
              @animation.try &.stop
              on_done
            end
          end
          @animation.try &.start
        end

        # Stop the animation. The fiber exits on its next iteration. Also
        # clears `@animation_paused`, so an explicit `#stop` issued while
        # hidden/detached sticks — the next `Event::Show`/`Event::Attached`
        # must not silently resume a run the caller deliberately ended.
        def stop
          @animation_paused = false
          @animation.try &.stop
        end

        def toggle
          running? ? stop : start
        end

        # Stops the clock for visibility (called from the one-time
        # `Event::Hide`/`Event::Detached` hooks installed by `#start`), unlike
        # a plain `#stop` this leaves `@animation_paused` set so it resumes
        # automatically once the widget is visible again — see
        # `Mixin::VisibilityPausedClock`.
        private def pause_animation : Nil
          @animation_paused = true if visibility_pause(@animation)
        end

        # Resumes a clock previously stopped by `#pause_animation` (called
        # from the one-time `Event::Show`/`Event::Attached` hooks), subject to
        # the visibility gate in
        # `Mixin::VisibilityPausedClock#visibility_resume?`. Rebuilds the
        # clock through `#start` (rather than restarting the stopped one), so
        # the run resumes with the current `#interval` and a fresh tick block.
        private def resume_animation : Nil
          return unless visibility_resume?(@animation_paused)
          @animation_paused = false
          start
        end

        # `{columns, rows}` of this widget's interior hidden by an ancestor clip
        # (a scrolled or `overflow: Hidden` container), for an effect that paints
        # a full-size field of which only a slice may be visible. `coords` moves
        # the rendered rect inward to the clip edge and records the clipped-off
        # top rows in `RenderedGeometry#base`; horizontal clipping has no `base`,
        # so the hidden column count is the distance from *origin_x* — the
        # unclipped interior origin (`aleft` + the left inset) — to the visible
        # interior left edge *xi*. Both are `0` when unclipped, including for a
        # widget merely off the window's top/left edge (negative coords, no
        # clipping ancestor — `base` stays 0 and `xi == origin_x` there).
        protected def clip_offsets(xi : Int32, origin_x : Int32) : {Int32, Int32}
          {Math.max(0, xi - origin_x), lpos.try(&.base) || 0}
        end

        # `{full_w, full_h, col_off, row_off}` for a full-field effect: the
        # unclipped interior size inside the given insets, plus the
        # `clip_offsets` mapping from the visible left edge *xi* into that field.
        # The four insets are passed distinctly (rather than as a single
        # horizontal/vertical total) so the size and the column origin stay
        # consistent — the origin uses `aleft + inset_left`, the width subtracts
        # both left and right. Callers choose which inset defines "interior":
        # `Direct#paint` passes the content insets (padding-inclusive), while
        # `SineScroller#paint` passes the border-only insets. Each keeps its
        # own early-return guard on the returned `full_w`/`full_h`.
        protected def full_field_geometry(
          xi : Int32,
          inset_left : Int32,
          inset_right : Int32,
          inset_top : Int32,
          inset_bottom : Int32,
        ) : {Int32, Int32, Int32, Int32}
          full_w = Math.max(0, awidth - inset_left - inset_right)
          full_h = Math.max(0, aheight - inset_top - inset_bottom)
          col_off, row_off = clip_offsets(xi, aleft + inset_left)
          {full_w, full_h, col_off, row_off}
        end
      end
    end
  end
end
