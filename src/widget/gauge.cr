require "./box"
require "../misc/glyph/scale"

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
    class Gauge < Box
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
      property segments : Array(Segment)?

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

      # Size of the value range (`maximum - minimum`), never zero (so divisions
      # are safe; an empty range simply renders empty).
      private def span : Float64
        s = @maximum - @minimum
        s <= 0 ? 1.0 : s
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
        ((@value - @minimum) / span * 100).clamp(0.0, 100.0)
      end

      def render
        self.content = build_content
        super
      end

      private def formatted_text : String
        @format
          .gsub("%p", percent.round.to_i.to_s)
          .gsub("%v", Graph::Scale.fmt(@value))
          .gsub("%m", Graph::Scale.fmt(@maximum))
          .gsub("%M", Graph::Scale.fmt(@minimum))
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

      # Stacked-mode fill: consecutive whole-cell runs, one per segment.
      private def fill_segments(segs, cells, colors) : Nil
        cols = cells.size
        x = 0
        segs.each do |seg|
          w = (cols * (seg.value / span)).round.to_i
          w.times do
            break if x >= cols
            cells[x] = Graph::Scale::FULL
            colors[x] = seg.color || @fill_color
            x += 1
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
          x = 0
          segs.each do |seg|
            w = (cols * (seg.value / span)).round.to_i
            if (lbl = seg.label) && w > 0
              overlay(cells, colors, x + Math.max(0, (w - lbl.size) // 2), lbl)
            end
            x += w
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
