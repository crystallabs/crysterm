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
      include Mixin::PercentRange
      include Mixin::RangeText

      # One colored slice of a stacked gauge.
      struct Segment
        # The slice's value, measured on the gauge's `minimum`..`maximum` span.
        property value : Float64
        # Foreground color for the slice, a native `0xRRGGBB` `Int32`. `nil` uses
        # the gauge's `style.fg`. A color name/`"#rrggbb"` string is accepted and
        # converted at assignment.
        getter color : Int32?
        # Optional caption drawn (centered) inside the slice.
        property label : String?

        def initialize(value : Number, color : Int32 | String? = nil, @label : String? = nil)
          @value = value.to_f
          @color = Colors.to_native color
        end

        # Assigns the slice color, converting a color name/`"#rrggbb"` string to a
        # native `0xRRGGBB` int.
        def color=(c : Int32 | String?) : Int32?
          @color = Colors.to_native c
        end
      end

      # Lower/upper bounds of the value range (inclusive). With the defaults
      # (0..100) a value equals its percentage.
      getter minimum : Float64
      getter maximum : Float64

      # Sets both bounds at once (Qt's `setRange`). Rejects a non-finite bound
      # outright (NaN survives `max < min` and would poison `#percent` and the
      # render fiber's `.round.to_i`), keeping the previous valid range. Never
      # stores an inverted range (a max below min collapses to min), re-clamps
      # `#value` into the new range, and repaints on an actual change.
      def set_range(min : Float64, max : Float64) : Nil
        return unless nm = normalize_range(min, max)
        @minimum, @maximum = nm
        @value = @value.clamp(@minimum, @maximum)
        request_render
      end

      # Whether to draw the inline percentage label (single mode) / segment
      # captions (stacked mode).
      getter? show_label : Bool

      # Assigns `#show_label?` and schedules a repaint: the content cache's key
      # includes `@show_label` so a bare `property` setter's change would only
      # take effect on some later, unrelated frame.
      def show_label=(v : Bool) : Bool
        return v if v == @show_label
        @show_label = v
        request_render
        v
      end

      # Template for the single-mode label. Placeholders, as in
      # `ProgressBar#format`: `%p` percentage, `%v` value, `%m` maximum,
      # `%M` minimum.
      getter format : String

      # Assigns `#format` and schedules a repaint (see `#show_label=`).
      def format=(v : String) : String
        return v if v == @format
        @format = v
        request_render
        v
      end

      # Fill color for single mode (and the default for segments without their
      # own color), a native `0xRRGGBB` `Int32`. `nil` uses the widget's
      # `style.fg`. A color name/`"#rrggbb"` string is accepted and converted.
      getter fill_color : Int32?

      # Assigns the fill color (accepting a color name/`"#rrggbb"` string) and
      # schedules a repaint.
      def fill_color=(c : Int32 | String?) : Int32?
        @fill_color = to_color c
        request_render
        @fill_color
      end

      # Converts a color spec to a native `0xRRGGBB` int (a name/`"#rrggbb"`
      # string via the shared conversion path), or `nil`.
      private def to_color(c : Int32 | String?) : Int32?
        Colors.to_native c
      end

      # A slice/fill color as a `#rrggbb` tag string for `Graph::Scale.tagged_row`,
      # or `nil` (no color → the widget's own `style.fg`). Mirrors `GaugeList`.
      private def color_tag(c : Int32?) : String?
        (c && c >= 0) ? Colors.hex(c) : nil
      end

      # Stacked-mode slices, laid left-to-right. When set (and non-empty) the
      # gauge renders as a stack and `#value` is ignored.
      getter segments : Array(Segment)?

      # Bumped whenever `#segments` is replaced, so the content cache can detect a
      # stacked-data change with a cheap integer compare. Callers that mutate the
      # array in place must reassign through `#segments=` to register.
      @segments_version = 0

      # Replaces the stacked segments and schedules a repaint.
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
        fill_color : Int32 | String? = nil,
        @segments : Array(Segment)? = nil,
        **box,
      )
        @fill_color = Colors.to_native fill_color
        # A non-finite bound would bypass `#set_range`'s guard and poison
        # `#percent_of`, crashing the render fiber on `.round.to_i`.
        @minimum, @maximum = sanitize_range(@minimum.to_f, @maximum.to_f)
        # Non-finite input would survive `clamp` (NaN compares false) and later
        # crash the render fiber on `.round.to_i`; sanitize at ingestion.
        @value = sanitize_value(value.to_f).clamp(@minimum, @maximum)
        super **box
        self.parse_tags = true
      end

      # Current value, within `[minimum, maximum]`.
      def value : Float64
        @value
      end

      # Sets the value, clamping into range. Emits `Event::DoubleValueChanged` on
      # an actual change, and `Event::Completed` upon reaching `#maximum`.
      def value=(v : Number) : Float64
        assign_completable(v) { request_render }
      end

      # Current fill as a `0..100` percentage of the range.
      def percent : Float64
        percent_of @value
      end

      # Sets the fill from a `0..100` percentage by mapping it back onto the
      # range; the inverse of `#percent`.
      def percent=(pct : Number) : Float64
        self.value = @minimum + pct.to_f.clamp(0.0, 100.0) * span / 100.0
      end

      # Snapshot of every input `build_content` reads; rebuilding the tagged
      # content allocates per row, and `set_content` dedups an identical result
      # but not the build itself. Must stay allocation-free per frame. The
      # trailing `glyph_key(style)` covers every input the fill ramp resolves
      # from, so a tier upgrade or CSS `glyphs:` hot-reload rebuilds instead of
      # keeping a stale ramp.
      @content_key : Tuple(Float64, Int32, Int32, Int32, Int32, Int32?, Bool, String, Float64, Float64, Int32, {String?, Glyphs::Tier, UInt64})? = nil

      def render(with_children = true)
        key = {@value, awidth, aheight, ihorizontal, ivertical, @fill_color, @show_label, @format, @minimum, @maximum, @segments_version,
               glyph_key(style)}
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
        cols = awidth - ihorizontal
        rows = aheight - ivertical
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

      # Single-mode fill: sub-cell horizontal blocks up to `#percent`. The fill
      # ramp resolves CSS-first (`Gauge { glyphs: " ▏▎▍▌▋▊▉█" }`), then the
      # registry's `ScaleHorizontal` at the effective tier.
      private def fill_single(cells, colors) : Nil
        cols = cells.size
        ramp = glyph_seq(Glyphs::SeqRole::ScaleHorizontal, style, cells: true)
        eighths = Graph::Scale.eighths(@value, @minimum, @maximum, cols)
        fc = color_tag @fill_color
        cols.times do |c|
          glyph = Graph::Scale.ramp_glyph(ramp, eighths, c)
          next if glyph == ' '
          cells[c] = glyph
          colors[c] = fc
        end
      end

      # Whole-cell `{start, width}` span occupied by each segment, clipped to
      # `cols` and laid left-to-right. Shared by the fill and caption overlay
      # so captions can't drift off their slice.
      private def segment_spans(segs, cols : Int32) : Array({Int32, Int32})
        x = 0
        segs.map do |seg|
          # A non-finite or huge share would overflow `.round.to_i` inside the
          # render fiber; treat non-finite as an empty slice and clamp the rest.
          share = seg.value / span
          share = 0.0 unless share.finite?
          w = (cols * share.clamp(0.0, 1.0)).round.to_i
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
          sc = color_tag(seg.color || @fill_color)
          w.times do |k|
            x = start + k
            cells[x] = Graph::Scale::FULL
            colors[x] = sc
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
          # Overlay right-to-left: a wide caption deletes a slot from `cells`,
          # shifting every later index, so processing the highest-index
          # (rightmost) segment first keeps not-yet-overlaid spans' `start`
          # positions valid. See `Graph::Scale.overlay_text`.
          (segs.size - 1).downto(0) do |i|
            seg = segs[i]
            start, w = spans[i]
            if (lbl = seg.label) && w > 0
              at = start + Math.max(0, (w - str_width(lbl)) // 2)
              Graph::Scale.overlay_text(cells, colors, at, lbl, full_unicode?)
            end
          end
        else
          Graph::Scale.overlay_text(cells, colors, 1, formatted_text, full_unicode?)
        end

        String.build { |io| Graph::Scale.tagged_row(io, cells, colors) }
      end
    end
  end
end
