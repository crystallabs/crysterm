module Crysterm
  module Mixin
    # Shared core of the "stop the frame clock while the widget can't be seen,
    # restart it once it can" lifecycle, used by every self-driven `FrameClock`
    # on a widget (`Widget#pulse`, `Widget::Effect::Animated`).
    #
    # The pattern each user wires up is always the same four parts:
    #
    # 1. a `*_paused` flag, set only when the clock was stopped *for
    #    visibility* (as opposed to an explicit `#stop`/`#stop_fade`);
    # 2. `Event::Hide`/`Event::Detached` hooks calling the pause half — the
    #    fiber would otherwise keep ticking `step`/`set_opacity` +
    #    `request_render` forever on a widget that is never painted (a hidden
    #    widget's `coords` is nil so `render` never runs, and a
    #    detached-but-alive widget's `request_render` no-ops while the clock
    #    still burns CPU);
    # 3. `Event::Show`/`Event::Attached` hooks calling the resume half;
    # 4. the explicit stop clearing the flag, so a deliberate stop issued while
    #    hidden isn't silently undone by the next show.
    #
    # This module owns parts 2 and 3 — the flag discipline and the visibility
    # gate — while each user keeps its own flag, its own extra eligibility
    # guard, and its own restart action (they legitimately differ: `#pulse`
    # restarts the *same* clock to stay phase-continuous, `Animated#start`
    # rebuilds one).
    #
    # The including type must be a `Widget` (`#visible_in_tree?`, `#window?`).
    module VisibilityPausedClock
      # Whether a clock paused for visibility may run again *now*.
      #
      # `Event::Show`/`Event::Attached` broadcast to every descendant
      # unconditionally, so a still-hidden widget inside a newly-shown
      # container (or a widget shown but not yet attached to a window) must not
      # resume; its paused flag stays set for a later show/attach that does
      # make it visible.
      private def resume_allowed? : Bool
        visible_in_tree? && !window?.nil?
      end

      # Stops *clock* for visibility and reports whether it did — i.e. whether
      # the caller should now set its `*_paused` flag. A no-op (returning
      # `false`) when there is no clock, when it isn't running, or when the
      # caller's own *eligible* guard fails; the flag then stays untouched.
      #
      # Idempotent against `Event::Hide`'s broadcast to every descendant
      # regardless of their own visibility.
      private def visibility_pause(clock : FrameClock?, eligible : Bool = true) : Bool
        return false unless clock && eligible && clock.running?
        clock.stop
        true
      end

      # Whether a resume should proceed: the clock was stopped by
      # `#visibility_pause` (*paused*) and the widget is visible again
      # (`#resume_allowed?`). Any extra per-caller guard is checked by the
      # caller around this, as is clearing the flag and performing the restart
      # — the right restart differs per user.
      private def visibility_resume?(paused : Bool) : Bool
        paused && resume_allowed?
      end
    end
  end
end
