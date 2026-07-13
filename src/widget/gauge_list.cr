require "./box"
require "../widget_graph_scale"
require "../mixin/ranged_value"

module Crysterm
  class Widget
    # A vertical list of labeled horizontal gauges — blessed-contrib's
    # `gauge-list`. Each row is `label … [▆▆▆▆▆     ] nn%`: a caption, a sub-cell
    # block bar (8× horizontal resolution, like `Gauge`), and a percentage. In
    # the spirit of a Qt list of `QProgressBar`s sharing one range.
    #
    # ```
    # gl = Widget::GaugeList.new parent: s, width: 30, height: 5,
    #   style: Style.new(border: true)
    # gl.add_gauge "cpu", 64
    # gl.add_gauge "mem", 88, 0xE05050
    # gl.add_gauge "net", 22
    # gl["mem"] = 91 # update by label
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![GaugeList screenshot](../../tests/widget/gauge_list/gauge_list.5s.apng)
    # <!-- /widget-examples:capture -->
    class GaugeList < Box
      # Float-valued `#span`/`#percent_of` helpers (shared with `Gauge`).
      include Mixin::PercentRange

      # One gauge row.
      class Item
        property label : String
        property value : Float64
        property color : Int32

        def initialize(@label, value : Number, @color : Int32)
          @value = value.to_f
        end
      end

      # Default per-row colors, cycled by row index.
      DEFAULT_COLORS = [0x40E0D0, 0xE0A040, 0x60C040, 0xD060C0, 0x4090E0, 0xE05050]

      # Shared value range for every gauge.
      property minimum : Float64
      property maximum : Float64

      # Columns reserved for the label column (`0` = auto from the labels).
      property label_width : Int32

      getter gauges : Array(Item) = [] of Item

      # Bumped whenever the gauge set changes (append / value set / clear), so
      # `#render`'s content-cache key can detect a data change with a cheap
      # integer compare instead of mapping `@gauges` to a fresh tuple array every
      # frame. Mutating an `Item` directly (rather than through `#[]=`) won't
      # register — go through the documented setters.
      @version = 0

      def initialize(@minimum : Number = 0.0, @maximum : Number = 100.0,
                     @label_width : Int32 = 0, **box)
        @minimum = @minimum.to_f
        @maximum = @maximum.to_f
        super **box
        self.parse_tags = true
      end

      # Appends a gauge. A `nil` color is auto-assigned from `DEFAULT_COLORS`.
      def add_gauge(label : String, value : Number = 0, color : Int32? = nil) : Item
        item = Item.new label, sanitize_value(value), color || DEFAULT_COLORS[@gauges.size % DEFAULT_COLORS.size]
        @gauges << item
        @version &+= 1
        request_render
        item
      end

      # Sets a gauge's value by row index.
      def []=(index : Int, value : Number) : Nil
        if item = @gauges[index]?
          item.value = sanitize_value(value)
          @version &+= 1
          request_render
        end
      end

      # Sets a gauge's value by label (first match).
      def []=(label : String, value : Number) : Nil
        if item = @gauges.find { |i| i.label == label }
          item.value = sanitize_value(value)
          @version &+= 1
          request_render
        end
      end

      # Coerces non-finite input to `@minimum` at ingestion: NaN survives every
      # later `clamp` (comparisons with NaN are false) and would crash the
      # render fiber on `pct.round.to_i`.
      private def sanitize_value(value : Number) : Float64
        v = value.to_f
        v.finite? ? v : @minimum
      end

      def clear : Nil
        @gauges.clear
        @version &+= 1
        request_render
      end

      # Snapshot of every input `build_content` reads. Rebuilding the tagged
      # content allocates per-cell arrays + a `String.build` per gauge every
      # frame; skip it while nothing observable changed. The gauge set is
      # represented by `@version` (bumped in `#add_gauge`/`#[]=`/`#clear`) rather
      # than mapping `@gauges` to a fresh tuple array, so the key stays
      # allocation-free per frame.
      # The trailing `glyph_key(style)` element covers every input `glyph_seq`
      # resolves the fill ramp from, so a post-probe tier upgrade / `Glyphs.set`
      # / CSS `glyphs:` hot-reload rebuilds the content instead of keeping a
      # stale ramp.
      @content_key : Tuple(Int32, Int32, Int32, Int32, Int32, Float64, Float64, Int32, {String?, Glyphs::Tier, UInt64})? = nil

      def render
        key = {awidth, aheight, iwidth, iheight, @label_width, @minimum, @maximum, @version,
               glyph_key(style)}
        if key != @content_key
          @content_key = key
          self.content = build_content
        end
        super
      end

      private def build_content : String
        cols = awidth - iwidth
        rows = aheight - iheight
        return "" if cols <= 0 || rows <= 0 || @gauges.empty?

        lw = @label_width
        # Size the label column by *display width*, not codepoint count: a wide
        # (CJK/emoji) grapheme is one codepoint but two terminal columns, so
        # `.size` under-measures and the label overflows into the bar.
        lw = (@gauges.max_of? { |g| str_width(g.label) } || 0) if lw <= 0
        lw = lw.clamp(0, Math.max(0, cols - 8)) # leave room for bar + " nn%"

        pct_w = 5 # " 100%"
        bar_cols = cols - lw - 1 - pct_w
        return "" if bar_cols <= 0

        shown = @gauges.first(rows)
        shown.map { |item| gauge_line item, lw, bar_cols, pct_w }.join('\n')
      end

      private def gauge_line(item : Item, lw : Int32, bar_cols : Int32, pct_w : Int32) : String
        pct = percent_of item.value
        # Row is exactly `lw + 1 (gap) + bar_cols + pct_w` cells wide; reserve
        # up front since these are rebuilt every gauge every animated frame.
        cap = lw + 1 + bar_cols + pct_w
        cells = Array(Char).new(cap)
        colors = Array(String?).new(cap)

        # Label (default style), fit to exactly `lw` *display columns* so a wide
        # grapheme (1 codepoint, 2 columns) doesn't push the bar/percentage past
        # the border and wrap the row. Emit chars until the next would overflow
        # the column, then pad the remaining columns with spaces.
        used = 0
        item.label.each_char do |ch|
          cw = str_width(ch.to_s)
          break if used + cw > lw
          cells << ch
          colors << nil
          used += cw
        end
        (lw - used).times do
          cells << ' '
          colors << nil
        end
        cells << ' '
        colors << nil

        # Bar: sub-cell horizontal block fill in the row's color. The ramp
        # resolves CSS-first (`glyphs:`), then the registry (GLYPHS.md §3.4).
        hexcolor = Colors.hex(item.color)
        ramp = glyph_seq(Glyphs::SeqRole::ScaleHorizontal, style, cells: true)
        eighths = Graph::Scale.eighths(item.value, @minimum, @maximum, bar_cols)
        bar_cols.times do |c|
          glyph = Graph::Scale.ramp_glyph(ramp, eighths, c)
          cells << glyph
          colors << (glyph == ' ' ? nil : hexcolor)
        end

        # Percentage (default style), right-aligned in its field.
        text = "#{pct.round.to_i}%".rjust(pct_w)
        text.each_char do |ch|
          cells << ch
          colors << nil
        end

        String.build { |io| Graph::Scale.tagged_row(io, cells, colors) }
      end
    end
  end
end
