require "./input"
require "../mixin/ranged_value"

module Crysterm
  class Widget
    # Abstract base for the slider family, modeled after Qt's `QAbstractSlider`.
    #
    # Holds the shared bounded-integer value/range behavior
    # (`#minimum`/`#maximum`/`#value`/`#step`/`#page_step`/`#wrapping?`,
    # `#step_up`/`#step_down`, `Event::ValueChanged`) via `Mixin::RangedValue`.
    abstract class AbstractSlider < Input
      include Mixin::RangedValue(Int32)

      # A slider/dial/scrollbar draws a fixed-size track/knob/trough; it should
      # not shrink to its (empty) content the way an `Input` does by default.
      @shrink_to_fit = false

      # Amount Page Up/Down move the value by (Qt's `pageStep`).
      property page_step : Int32 = 10

      # Qt's `QAbstractSlider#tracking`: when `true` (the default), `#value`
      # updates live as the handle is dragged. When `false`, dragging updates
      # only `#slider_position` (and the rendered handle), committing to
      # `#value` on release.
      property? tracking : Bool = true

      # Live handle position while an untracked drag is in progress; `nil`
      # otherwise (in which case `#slider_position` falls back to `#value`).
      @slider_position : Int32? = nil

      # Qt's `sliderPosition`: the handle's current position. Equal to `#value`
      # except mid-drag when `#tracking?` is `false`.
      def slider_position : Int32
        @slider_position || @value
      end

      # Moves the handle to *v*. With `#tracking?` this commits straight to
      # `#value`; without it the handle moves but `#value` stays put until
      # release (`#commit_slider_position`).
      def slider_position=(v : Int32) : Int32
        v = v.clamp(@minimum, @maximum)
        if tracking?
          self.value = v
        else
          @slider_position = v
          update!
        end
        v
      end

      # Commits a pending untracked drag (button release). Returns `true` when
      # there was one, so a mouse handler can accept the event on that basis.
      protected def commit_slider_position : Bool
        p = @slider_position
        return false unless p
        @slider_position = nil
        self.value = p
        update!
        true
      end

      # The prologue every linear track widget's `Event::Mouse` handler shares:
      # the wheel step, the untracked-drag commit on release, and the test for
      # "is this a press, or motion with a button held". Returns `true` only when
      # the caller should go on and resolve the pointer against the track; a
      # `false` means the event was consumed (wheel), already dealt with
      # (release), or simply isn't part of a drag gesture — so a handler block
      # spells it `next unless drag_gesture? e`.
      #
      # This is the "an untracked drag released off the bar must still commit"
      # contract; a track widget whose mouse handler only calls `#ranged_wheel`
      # silently has no release-commit path.
      #
      # *wheel_invert* flips the wheel's direction (a scroll bar's wheel-up moves
      # toward the smaller value).
      protected def drag_gesture?(e : ::Crysterm::Event::Mouse, *, wheel_invert : Bool = false) : Bool
        return false if ranged_wheel e, invert: wheel_invert

        if e.action.up?
          e.accept if commit_slider_position
          return false
        end

        e.action.down? || (e.action.move? && !e.button.none?)
      end

      # A committed value supersedes any pending untracked drag (`RangedValue`
      # hook).
      protected def on_value_changed
        @slider_position = nil
      end

      # Indicates focus via reverse-video at the unstyled floor.
      def floor_focus_reverse? : Bool
        true
      end

      # Whether `#handle_key_press`'s Up/Down (and Page/Home/End) stepping runs
      # inverted (`Mixin::RangedValue#ranged_step_key`'s *invert*).
      protected def step_key_inverted? : Bool
        false
      end

      # Arrow/Page/Home/End stepping.
      def handle_key_press(e)
        ranged_step_key e, invert: step_key_inverted?
      end

      # `@value` stamp for the subclasses' per-value string caches.
      @value_text_for : Int32?

      # Returns `true` — and advances the stamp — when `@value` has changed since
      # the last call, signalling a subclass to rebuild its cached value
      # string(s). The first call is always stale, so subclasses can seed their
      # string ivars with `""` rather than a nilable.
      private def value_text_stale? : Bool
        return false if @value_text_for == @value
        @value_text_for = @value
        true
      end

      # Value at a main-axis offset *pos* cells from the low-value end of a
      # *span*-cell track: `#minimum + round(pos/span · value_span)`. *pos* is
      # *not* clamped here — callers may pre-clamp it or let `#value=` clamp.
      # Returns `#minimum` for a non-positive span.
      protected def value_at(pos : Int32, span : Int32) : Int32
        return @minimum if span <= 0
        # Clamp the mapped offset into the value span before the Int32 conversion:
        # with an unclamped *pos*, an off-track drag on a large range would push
        # `pos.to_f * value_span / span` past `Int32::MAX` and make `.round.to_i`
        # raise `OverflowError`. Clamping yields the value `#value=` would clamp to.
        @minimum + (pos.to_f * value_span / span).round.clamp(0.0, value_span.to_f).to_i
      end

      # Main-axis cell offset (from the low-value end) of value *v* on an
      # *avail*-cell track: `round((v - #minimum) / value_span · avail)`, the
      # inverse of `#value_at`. *v* is `Int64` because a full-span range saturates
      # `value_span` at `Int32::MAX`, so `(v - #minimum) * avail` must widen or it
      # overflows Int32. No end-clamp here — callers guard `value_span`/`avail`
      # and clamp as their geometry requires.
      protected def value_to_cell(v : Int64, avail : Int32) : Int32
        ((v - @minimum).to_f * avail / value_span).round.to_i
      end
    end
  end
end
