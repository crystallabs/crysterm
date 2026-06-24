require "./box"

module Crysterm
  class Widget
    # Debug overlay that displays live rendering-performance figures for its
    # `Screen`: how fast the render and draw phases run, the resulting frame
    # rate, and how many bytes the draw phase writes to the terminal.
    #
    # It is an ordinary widget — position, style, show/hide and reparent it like
    # any other. What it prints is driven by a printf-style `#format` string and
    # a `#args` list naming which metrics fill the format's `%` slots, so any
    # element is "disabled" simply by leaving it out of `args`. The defaults
    # print everything:
    #
    #     Crysterm::Widget::Fps.new(parent: screen)            # everything, bottom-left
    #     Crysterm::Widget::Fps.new(parent: screen,
    #       format: "%s fps", args: [:fps])                    # just the frame rate
    #     Crysterm::Widget::Fps.new(parent: screen,
    #       format: "R %s  D %s  TX %s/s", args: [:render, :draw, :throughput_h])
    #
    # Available `args` (see `#value_for`):
    #   :render  :draw  :fps              current per-frame rates (Int)
    #   :render_avg  :draw_avg  :fps_avg  their rolling averages over the last
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
    # frames, so it reflects sustained traffic and integrates over time to
    # `:total`.
    #
    # The figures describe the *previous* frame (the overlay paints as a child,
    # before the frame it appears in has finished) — exactly what a frame-rate
    # counter wants.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Fps screenshot](../../examples/widget/fps/fps-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Fps < Box
      # Auto-size to its single line of text, like `Label`.
      @resizable = true

      # Default layout: the classic `R/D/FPS: cur/cur/cur (avg/avg/avg)` line,
      # plus terminal write throughput and the cumulative byte total.
      #
      # Every field is given a fixed minimum width (right-justified) so the line
      # keeps a constant length as the numbers gain or lose digits — otherwise
      # the auto-sized box would shrink/grow by a column and visibly jitter. The
      # `%s` specifiers accept both the integer and the human-readable string
      # metrics. (`5` fits any realistic frame rate; `9` fits "1023.9MiB".)
      DEFAULT_FORMAT = "R/D/FPS: %5s/%5s/%5s (%5s/%5s/%5s)  TX: %9s/s (%9s/s)  ~TX: %9s/s (%9s/s)  Σ: %9s"
      DEFAULT_ARGS   = %i[
        render draw fps
        render_avg draw_avg fps_avg
        throughput_h throughput_avg_h
        throughput_actual_h throughput_actual_avg_h
        total_h
      ]

      # printf-style template (see `String#%`); its `%` slots are filled, in
      # order, from `#args`.
      property format : String = DEFAULT_FORMAT

      # Metric names supplying the `#format` arguments, in order. See the class
      # docs / `#value_for` for the recognized symbols.
      property args : Array(Symbol) = DEFAULT_ARGS

      @render_avg : Screen::Average
      @draw_avg : Screen::Average
      @fps_avg : Screen::Average
      @throughput_avg : Screen::Average
      @throughput_actual_avg : Screen::Average

      # Averages computed once per frame in `#render` (so referencing a metric
      # zero or many times in `#format` never skews the rolling window).
      @render_avg_val : Int64 = 0
      @draw_avg_val : Int64 = 0
      @fps_avg_val : Int64 = 0
      @throughput_avg_val : Int64 = 0
      @throughput_actual_avg_val : Int64 = 0

      def initialize(parent = nil, *, format : String? = nil, args : Array(Symbol)? = nil, **opts)
        format.try { |f| @format = f }
        args.try { |a| @args = a }

        window = Config.render_fps_window
        @render_avg = Screen::Average.new window
        @draw_avg = Screen::Average.new window
        @fps_avg = Screen::Average.new window
        @throughput_avg = Screen::Average.new window
        @throughput_actual_avg = Screen::Average.new window

        super(parent, **opts)

        # Sit in the bottom-left corner (where the old built-in overlay lived)
        # unless the caller anchored it explicitly.
        if @left.nil? && @right.nil? && @top.nil? && @bottom.nil?
          @left = 0
          @bottom = 0
        end
      end

      def render(with_children = true)
        if s = screen?
          # Update the rolling averages exactly once per frame, then build the
          # text before the standard box render paints it.
          @render_avg_val = @render_avg.avg s.render_rate
          @draw_avg_val = @draw_avg.avg s.draw_rate
          @fps_avg_val = @fps_avg.avg s.frame_rate
          @throughput_avg_val = @throughput_avg.avg s.throughput
          @throughput_actual_avg_val = @throughput_actual_avg.avg s.throughput_actual

          text =
            begin
              @format % @args.map { |sym| value_for sym, s }
            rescue ex
              # A bad format/args combination shouldn't take down the render
              # loop; surface the problem in the overlay instead.
              "FPS format error: #{ex.message}"
            end
          set_content text
        end

        super
      end

      # Resolves a metric symbol to a printf-ready value (`Int64` for numbers,
      # `String` for the human-readable variants). Unknown symbols render as
      # `?name` rather than raising.
      private def value_for(sym : Symbol, s : Screen) : Int64 | String
        case sym
        when :render                  then s.render_rate.to_i64
        when :draw                    then s.draw_rate.to_i64
        when :fps                     then s.frame_rate.to_i64
        when :render_avg              then @render_avg_val
        when :draw_avg                then @draw_avg_val
        when :fps_avg                 then @fps_avg_val
        when :throughput              then s.throughput.to_i64
        when :throughput_avg          then @throughput_avg_val
        when :throughput_h            then humanize s.throughput
        when :throughput_avg_h        then humanize @throughput_avg_val
        when :throughput_actual       then s.throughput_actual.to_i64
        when :throughput_actual_avg   then @throughput_actual_avg_val
        when :throughput_actual_h     then humanize s.throughput_actual
        when :throughput_actual_avg_h then humanize @throughput_actual_avg_val
        when :total                   then s.bytes_written.to_i64
        when :total_h                 then humanize s.bytes_written
        else                               "?#{sym}"
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
