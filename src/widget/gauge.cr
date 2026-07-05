require "./box"
require "../widget_graph_scale"
require "../mixin/ranged_value"

module Crysterm
  class Widget
    # A horizontal meter, ported from blessed-contrib's `gauge`. Where
    # `Widget::ProgressBar` is an *interactive* Qt-style control (keys/mouse move
    # its value), `Gauge` is a *read-only display* tuned for dashboards: smooth
    # sub-cell fill via horizontal eighth-block glyphs, an inline percentage
    # label, and an optional *stacked* mode showing several colored segments in
    # one bar.
    #
    # In single mode the fill tracks `#value` within `[#minimum, #maximum]`
    # (defaults `0`..`100`, so a value reads as its own percentage). In stacked
    # mode, set `#segments` to a list of `Gauge::Segment`s laid left-to-right,
    # each sized by its value against the `#minimum`..`#maximum` span.
    #
    # ```
    # g = Widget::Gauge.new parent: s, width: 40, height: 1, value: 65,
    #   fill_color: "cyan"
    #
    # g2 = Widget::Gauge.new parent: s, width: 40, height: 1, segments: [
    #   Widget::Gauge::Segment.new(40, "green", "ok"),
    #   Widget::Gauge::Segment.new(35, "yellow", "warn"),
    #   Widget::Gauge::Segment.new(25, "red", "crit"),
    # ]
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Gauge screenshot](../../tests/widget/gauge/gauge.5s.apng)
    # <!-- /widget-examples:capture -->
    class Gauge < Box
      # Float-valued `#span`/`#percent_of` helpers (shared with `GaugeList`).
      include Mixin::PercentRange
      # `%p`/`%v`/`%m`/`%M` template expansion (shared with `ProgressBar`).
      include Mixin::RangeText

      # One colored slice of a stacked gauge.
      struct Segment
        # The slice's value, measured on the gauge's `minimum`..`maximum` span.
        property value : Float64
        # Foreground color for the slice. `nil` uses the gauge's `style.fg`.
        property color : String?
        # Optional caption drawn (centered) inside the slice.
        property label : String?

        def initialize(value : Number, @color : String? = nil, @label : String? = nil)
          @value = value.to_f
        end
      end

      # Lower/upper bounds of the value range (inclusive). With the defaults
      # (0..100) a value equals its percentage.
      property minimum : Float64
      property maximum : Float64

      # Whether to draw the inline percentage label (single mode) / segment
      # captions (stacked mode).
      property? show_label : Bool

      # Template for the single-mode label. Placeholders, as in
      # `ProgressBar#text_format`: `%p` percentage, `%v` value, `%m` maximum,
      # `%M` minimum.
      property format : String

      # Fill color for single mode (and the default for segments without their
      # own color). `nil` uses the widget's `style.fg`.
      property fill_color : String?

      # Stacked-mode slices, laid left-to-right. When set (and non-empty) the
      # gauge renders as a stack and `#value` is ignored.
      getter segments : Array(Segment)?

      # Bumped whenever `#segments` is replaced, so `#render`'s content-cache key
      # can detect a stacked-data change with a cheap integer compare instead of
      # snapshotting the array (an `@segments.dup` per frame). Callers that mutate
      # the array in place should assign a fresh/updated array through `#segments=`
      # (or bump via that setter) for the change to register.
      @segments_version = 0

      # Replaces the stacked segments, bumping `@segments_version` so the next
      # `#render` rebuilds the cached content, and scheduling that render so the
      # new data actually appears (as `#value=` does) instead of waiting for an
      # unrelated frame to repaint.
      def segments=(segs : Array(Segment)?) : Array(Segment)?
        @segments = segs
        @segments_version &+= 1
        request_render
        segs
      end

      @value : Float64

      def initialize(
        value : Number = 0,
        @minimum : Number = 0.0,
        @maximum : Number = 100.0,
        @show_label : Bool = true,
        @format : String = "%p%",
        @fill_color : String? = nil,
        @segments : Array(Segment)? = nil,
        **box,
      )
        @minimum = @minimum.to_f
        @maximum = @maximum.to_f
        @value = value.to_f.clamp(@minimum, @maximum)
        super **box
        self.parse_tags = true
      end

      # Current value, within `[minimum, maximum]`.
      def value : Float64
        @value
      end

      # Sets the value, clamping into range. Emits `Event::DoubleValueChange`
      # (the `Float64` value event, as in `DoubleSpinBox`) on an actual change,
      # and `Event::Complete` upon reaching `#maximum`.
      def value=(v : Number) : Float64
        v = v.to_f.clamp(@minimum, @maximum)
        return v if v == @value
        @value = v
        emit Crysterm::Event::DoubleValueChange, @value
        emit Crysterm::Event::Complete if @value == @maximum && @maximum > @minimum
        request_render
        @value
      end

      # Current fill as a `0..100` percentage of the range.
      def percent : Float64
        percent_of @value
      end

      # Snapshot of every input `build_content` reads. Rebuilding the tagged
      # content string allocates per-cell arrays + a `String.build` per row every
      # frame; `set_content` already dedups an identical result, but not the
      # build itself. Skip it while nothing observable changed. The stacked
      # segments are represented by `@segments_version` (bumped in `#segments=`)
      # rather than an `@segments.dup`, so the key stays allocation-free per frame.
      @content_key : Tuple(Float64, Int32, Int32, Int32, Int32, String?, Bool, String, Float64, Float64, Int32)? = nil

      def render
        key = {@value, awidth, aheight, iwidth, iheight, @fill_color, @show_label, @format, @minimum, @maximum, @segments_version}
        if key != @content_key
          @content_key = key
          self.content = build_content
        end
        super
      end

      private def formatted_text : String
        format_range_text @format, percent.round.to_i.to_s, Graph::Scale.fmt(@value), Graph::Scale.fmt(@maximum), Graph::Scale.fmt(@minimum)
      end

      private def build_content : String
        cols = awidth - iwidth
        rows = aheight - iheight
        return "" if cols <= 0 || rows <= 0

        cells = Array(Char).new(cols, ' ')
        colors = Array(String?).new(cols, nil)

        if (segs = @segments) && !segs.empty?
          fill_segments(segs, cells, colors)
        else
          fill_single(cells, colors)
        end

        # Every row shows the same bar; the label rides the middle row.
        row = String.build { |io| Graph::Scale.tagged_row(io, cells, colors) }
        mid = rows // 2
        Array.new(rows) { |r| r == mid ? with_labels(segs, cells, colors) : row }.join('\n')
      end

      # Single-mode fill: sub-cell horizontal blocks up to `#percent`.
      private def fill_single(cells, colors) : Nil
        cols = cells.size
        eighths = Graph::Scale.eighths(@value, @minimum, @maximum, cols)
        cols.times do |c|
          glyph = Graph::Scale.hglyph(eighths, c)
          next if glyph == ' '
          cells[c] = glyph
          colors[c] = @fill_color
        end
      end

      # Whole-cell `{start, width}` span occupied by each segment, clipped to
      # `cols` and laid left-to-right. Shared by the fill and caption overlay
      # so captions can't drift off their slice.
      private def segment_spans(segs, cols : Int32) : Array({Int32, Int32})
        x = 0
        segs.map do |seg|
          w = (cols * (seg.value / span)).round.to_i
          w = 0 if w < 0
          w = cols - x if x + w > cols
          start = x
          x += w
          {start, w}
        end
      end

      # Stacked-mode fill: consecutive whole-cell runs, one per segment.
      private def fill_segments(segs, cells, colors) : Nil
        cols = cells.size
        spans = segment_spans(segs, cols)
        segs.each_with_index do |seg, i|
          start, w = spans[i]
          w.times do |k|
            x = start + k
            cells[x] = Graph::Scale::FULL
            colors[x] = seg.color || @fill_color
          end
        end
      end

      # Renders the middle row with captions overlaid (single percentage, or one
      # caption centered within each segment). Overlaid characters drop their
      # color so the text stays legible against the fill.
      private def with_labels(segs, base_cells, base_colors) : String
        return String.build { |io| Graph::Scale.tagged_row(io, base_cells, base_colors) } unless show_label?

        cells = base_cells.dup
        colors = base_colors.dup
        cols = cells.size

        if segs && !segs.empty?
          spans = segment_spans(segs, cols)
          segs.each_with_index do |seg, i|
            start, w = spans[i]
            if (lbl = seg.label) && w > 0
              overlay(cells, colors, start + Math.max(0, (w - lbl.size) // 2), lbl)
            end
          end
        else
          overlay(cells, colors, 1, formatted_text)
        end

        String.build { |io| Graph::Scale.tagged_row(io, cells, colors) }
      end

      private def overlay(cells, colors, at : Int32, text : String) : Nil
        text.each_char_with_index do |ch, i|
          x = at + i
          next if x < 0 || x >= cells.size
          cells[x] = ch
          colors[x] = nil
        end
      end
    end
  end
end
