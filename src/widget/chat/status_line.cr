require "../../chat/glyphs"
require "../../chat/mode"
require "../status_bar"
require "../loading"

module Crysterm
  class Widget
    module Chat
      # The chat status line: a one-row `StatusBar` under the input, showing
      # the permission-mode badge, running-task count and contextual hints as
      # a `·`-separated strip, with a sparkle spinner (a compact `Loading`)
      # overlaid while the backend is busy.
      #
      # `Shift+Tab` cycles `#mode` through the `Chat::Mode` machine; each
      # change restyles the badge (tag-colored per `Chat::Mode#color`) and
      # emits `Event::CurrentChanged` carrying the new mode's value.
      #
      # `#busy` shows the spinner over the strip with
      # `<frame> <label> (Ns · esc to interrupt)`, the elapsed readout
      # recomputed on every spinner frame; `#idle` hides it again. The
      # permanent (right-aligned) `StatusBar` sections stay visible either
      # way — they are drawn over the spinner.
      # Excluded from the DOM-loader registry: self-populating composite
      # (see `Crysterm::DOM::Skip`).
      @[::Crysterm::DOM::Skip]
      class StatusLine < StatusBar
        # A compact `Loading` whose text is recomputed from `#text_source` on
        # every frame, so a live readout (the elapsed seconds) advances with the
        # spinner instead of freezing at `start`-time.
        @[::Crysterm::DOM::Skip]
        class BusySpinner < Loading
          # Produces the text painted with the next frame. Deliberately not
          # named `label` — that would shadow `Widget#label : String?` with an
          # incompatible type and break widget-generic callers.
          property text_source : Proc(String) = -> { "" }

          def step
            @text = text_source.call
            super
          end
        end

        # The busy spinner, shown over the strip while running (`#busy`).
        getter spinner : BusySpinner

        # The current permission mode.
        getter mode : ::Crysterm::Chat::Mode = :normal

        # Contextual hint segments appended after the badge and task readout.
        getter hints = [] of String

        # Number of running tasks; rendered as `N task(s) running`, omitted
        # at zero.
        getter task_count = 0

        # Spinner label used when `#busy` is called without a text.
        property busy_label : String = "Thinking#{::Crysterm::Chat::Glyphs::ELLIPSIS}"

        # Hint appended to the busy readout, after the elapsed seconds.
        property interrupt_hint : String = "esc to interrupt"

        # Badge/strip styling uses the `{}`-tag pipeline.
        @parse_tags = true

        @busy_text = ""
        @busy_started : Time::Instant = Time.instant

        def initialize(**status_bar)
          super **{keys: true}.merge(status_bar)

          @spinner = BusySpinner.new \
            compact: true,
            frames: ::Crysterm::Chat::Glyphs::SPINNER_FRAMES.to_a,
            left: 0,
            top: 0,
            height: 1,
            width: "100%"
          @spinner.text_source = -> { busy_line }
          append @spinner
          @spinner.hide

          if @keys
            on ::Crysterm::Event::KeyPress, ->handle_status_key_press(::Crysterm::Event::KeyPress)
          end

          refresh_strip
        end

        # Sets the permission mode, restyling the badge and emitting
        # `Event::CurrentChanged` with the new mode's value; a no-op when
        # unchanged.
        def mode=(mode : ::Crysterm::Chat::Mode) : ::Crysterm::Chat::Mode
          return mode if mode == @mode
          @mode = mode
          refresh_strip
          emit ::Crysterm::Event::CurrentChanged, mode.value
          mode
        end

        # Advances `#mode` to the next mode in cycle order, wrapping (the
        # `Shift+Tab` action). Returns the new mode.
        def cycle_mode : ::Crysterm::Chat::Mode
          self.mode = @mode.next
          @mode
        end

        # Replaces the hint segments and repaints the strip.
        def hints=(hints : Array(String)) : Array(String)
          @hints = hints
          refresh_strip
          hints
        end

        # Sets the running-task count and repaints the strip; a no-op when
        # unchanged.
        def task_count=(count : Int32) : Int32
          return count if count == @task_count
          @task_count = count
          refresh_strip
          count
        end

        # Enters the busy state: shows the spinner (labeled *text*, or
        # `#busy_label`) over the strip and starts its frame loop, resetting
        # the elapsed clock.
        def busy(text : String? = nil) : Nil
          @busy_text = text || @busy_label
          @busy_started = Time.instant
          @spinner.start busy_line
        end

        # Whether the busy spinner is currently shown and animating.
        def busy? : Bool
          @spinner.running?
        end

        # Leaves the busy state: stops and hides the spinner, revealing the
        # strip again.
        def idle : Nil
          @spinner.stop
          update!
        end

        # Time since the last `#busy` call.
        def busy_elapsed : Time::Span
          Time.instant - @busy_started
        end

        # `Shift+Tab` cycles the permission mode.
        def handle_status_key_press(e : ::Crysterm::Event::KeyPress)
          return unless e.key == ::Tput::Key::ShiftTab
          cycle_mode
          e.accept
        end

        # The spinner's text (sans frame glyph — `Loading`'s compact render
        # prepends that): busy label plus `(Ns · <interrupt hint>)`.
        private def busy_line : String
          "#{@busy_text} (#{busy_elapsed.total_seconds.to_i}s" \
          "#{::Crysterm::Chat::Glyphs::SEP}#{@interrupt_hint})"
        end

        # Rebuilds the strip — badge, task count, hints, `·`-separated — into
        # the bar's (left) message.
        private def refresh_strip : Nil
          segments = [] of String
          mode_badge.try { |badge| segments << badge }
          if @task_count > 0
            segments << "#{@task_count} task#{"s" if @task_count != 1} running"
          end
          segments.concat @hints
          show_message segments.join ::Crysterm::Chat::Glyphs::SEP
        end

        # The tag-colored mode badge, or `nil` in `Normal` mode (no badge).
        private def mode_badge : String?
          label = @mode.label
          return if label.empty?
          if color = @mode.color
            "{#{color}-fg}#{label}{/#{color}-fg}"
          else
            label
          end
        end
      end
    end
  end
end
