require "./box"

module Crysterm
  class Widget
    # Debug overlay showing live rendering-performance figures for its
    # `Window`: render/draw phase speed, resulting frame rate, and bytes the
    # draw phase writes to the terminal.
    #
    # An ordinary widget — position, style, show/hide and reparent it like any
    # other. What it prints is driven by a printf-style `#format` string and an
    # `#args` list naming which metrics fill the format's `%` slots; an element
    # is disabled by leaving it out of `args`. Defaults print everything:
    #
    #     Crysterm::Widget::Fps.new(parent: window)            # everything, bottom-left
    #     Crysterm::Widget::Fps.new(parent: window,
    #       format: "%s fps", args: [Fps::Metric::Fps])        # just the frame rate
    #     Crysterm::Widget::Fps.new(parent: window,
    #       format: "R %s  D %s  TX %s/s",
    #       args: [Fps::Metric::Render, Fps::Metric::Draw, Fps::Metric::ThroughputH])
    #
    # Available `args`:
    #   :render  :draw  :flush  :fps      current per-frame rates (Int). `:draw`
    #                                     is the CPU-bound diff/encode; `:flush`
    #                                     is the terminal write (where tty
    #                                     backpressure shows up).
    #   :render_avg  :draw_avg  :flush_avg  :fps_avg
    #                                     their rolling averages over the last
    #                                     `Config.render_fps_window` frames (Int)
    #   :throughput      :throughput_avg      in-frame bytes/sec, raw integers
    #   :throughput_h    :throughput_avg_h    in-frame bytes/sec, human ("3.2KiB")
    #   :throughput_actual      :throughput_actual_avg      wall-clock bytes/sec
    #   :throughput_actual_h    :throughput_actual_avg_h    the same, human-readable
    #   :total           total bytes ever written to the terminal (Int)
    #   :total_h         the same, human-readable
    #
    # `:throughput` is the rate *while a frame paints* (what continuous rendering
    # would sustain); `:throughput_actual` divides by the real interval between
    # frames, reflecting sustained traffic, and integrates over time to `:total`.
    #
    # The figures describe the *previous* frame (the overlay paints as a child,
    # before the frame it appears in has finished).
    #
    # <!-- widget-examples:capture v1 -->
    # ![Fps screenshot](../../tests/widget/fps/fps.5s.apng)
    # <!-- /widget-examples:capture -->
    class Fps < Box
      # Metrics that `#args` may name, one per `%` slot `#format` fills. See
      # the class docs above for what each one reports.
      enum Metric
        Render
        Draw
        Flush
        Fps
        RenderAvg
        DrawAvg
        FlushAvg
        FpsAvg
        Throughput
        ThroughputAvg
        ThroughputH
        ThroughputAvgH
        ThroughputActual
        ThroughputActualAvg
        ThroughputActualH
        ThroughputActualAvgH
        Total
        TotalH
      end

      # Auto-size to its single line of text.
      @shrink_to_fit = true

      # Default layout: the classic `R/D/FPS: cur/cur/cur (avg/avg/avg)` line,
      # plus terminal write throughput and the cumulative byte total.
      #
      # Each field has a fixed minimum width (right-justified) so the line
      # keeps a constant length as digit counts change — otherwise the
      # auto-sized box would jitter. `%s` accepts both integer and
      # human-readable metrics. (`5` fits any realistic frame rate; `9` fits
      # "1023.9MiB".)
      DEFAULT_FORMAT = "R/D/FPS: %5s/%5s/%5s (%5s/%5s/%5s)  TX: %9s/s (%9s/s)  ~TX: %9s/s (%9s/s)  Σ: %9s"
      DEFAULT_ARGS   = [
        Metric::Render, Metric::Draw, Metric::Fps,
        Metric::RenderAvg, Metric::DrawAvg, Metric::FpsAvg,
        Metric::ThroughputH, Metric::ThroughputAvgH,
        Metric::ThroughputActualH, Metric::ThroughputActualAvgH,
        Metric::TotalH,
      ]

      # printf-style template (see `String#%`); its `%` slots are filled, in
      # order, from `#args`.
      property format : String = DEFAULT_FORMAT

      # Metrics supplying the `#format` arguments, in order. See the class
      # docs for the recognized values.
      property args : Array(Metric) = DEFAULT_ARGS

      @render_avg : Window::Average
      @draw_avg : Window::Average
      @flush_avg : Window::Average
      @fps_avg : Window::Average
      @throughput_avg : Window::Average
      @throughput_actual_avg : Window::Average

      # Averages computed once per frame in `#render` (so referencing a metric
      # zero or many times in `#format` never skews the rolling window).
      @render_avg_val : Int64 = 0
      @draw_avg_val : Int64 = 0
      @flush_avg_val : Int64 = 0
      @fps_avg_val : Int64 = 0
      @throughput_avg_val : Int64 = 0
      @throughput_actual_avg_val : Int64 = 0

      # Reused buffer for the printf argument list, refilled every frame instead
      # of allocating a fresh `@args.map { ... }` array. `String#%` accepts any
      # `Indexable`, so this feeds it directly.
      @fmt_args = [] of Int64 | String

      def initialize(*, format : String = DEFAULT_FORMAT, args : Array(Metric) = DEFAULT_ARGS, **opts)
        @format = format
        @args = args

        window = Config.render_fps_window
        @render_avg = Window::Average.new window
        @draw_avg = Window::Average.new window
        @flush_avg = Window::Average.new window
        @fps_avg = Window::Average.new window
        @throughput_avg = Window::Average.new window
        @throughput_actual_avg = Window::Average.new window

        super(**opts)

        # Default to the bottom-left corner unless the caller anchored it explicitly.
        if @left.nil? && @right.nil? && @top.nil? && @bottom.nil?
          @left = 0
          @bottom = 0
        end
      end

      def render(with_children = true)
        if s = window?
          @render_avg_val = @render_avg.avg s.render_rate
          @draw_avg_val = @draw_avg.avg s.draw_rate
          @flush_avg_val = @flush_avg.avg s.flush_rate
          @fps_avg_val = @fps_avg.avg s.frame_rate
          @throughput_avg_val = @throughput_avg.avg s.throughput
          @throughput_actual_avg_val = @throughput_actual_avg.avg s.throughput_actual

          text =
            begin
              @fmt_args.clear
              @args.each { |metric| @fmt_args << value_for metric, s }
              @format % @fmt_args
            rescue ex
              # Bad format/args combo shouldn't take down the render loop.
              "FPS format error: #{ex.message}"
            end
          set_content text
        end

        super
      end

      # Resolves a metric to a printf-ready value (`Int64` for numbers,
      # `String` for the human-readable variants).
      private def value_for(metric : Metric, s : Window) : Int64 | String
        case metric
        in .render?                  then s.render_rate.to_i64
        in .draw?                    then s.draw_rate.to_i64
        in .flush?                   then s.flush_rate.to_i64
        in .fps?                     then s.frame_rate.to_i64
        in .render_avg?              then @render_avg_val
        in .draw_avg?                then @draw_avg_val
        in .flush_avg?               then @flush_avg_val
        in .fps_avg?                 then @fps_avg_val
        in .throughput?              then s.throughput.to_i64
        in .throughput_avg?          then @throughput_avg_val
        in .throughput_h?            then humanize s.throughput
        in .throughput_avg_h?        then humanize @throughput_avg_val
        in .throughput_actual?       then s.throughput_actual.to_i64
        in .throughput_actual_avg?   then @throughput_actual_avg_val
        in .throughput_actual_h?     then humanize s.throughput_actual
        in .throughput_actual_avg_h? then humanize @throughput_actual_avg_val
        in .total?                   then s.bytes_written.to_i64
        in .total_h?                 then humanize s.bytes_written
        end
      end

      # Formats a byte count with the largest binary unit that keeps it >= 1,
      # so small values stay in plain bytes and large ones shrink to KiB/MiB/…
      private def humanize(bytes : Int) : String
        units = {"B", "KiB", "MiB", "GiB", "TiB", "PiB"}
        value = bytes.to_f
        unit = 0
        while value >= 1024 && unit < units.size - 1
          value /= 1024
          unit += 1
        end
        unit == 0 ? "#{bytes}#{units[0]}" : "%.1f%s" % {value, units[unit]}
      end
    end
  end
end
