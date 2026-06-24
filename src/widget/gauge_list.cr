require "./box"
require "../misc/glyph/scale"

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
    # ![GaugeList screenshot](../../examples/widget/gauge_list/gauge_list-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class GaugeList < Box
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

      def initialize(@minimum : Number = 0.0, @maximum : Number = 100.0,
                     @label_width : Int32 = 0, **box)
        @minimum = @minimum.to_f
        @maximum = @maximum.to_f
        super **box
        self.parse_tags = true
      end

      # Appends a gauge. A `nil` color is auto-assigned from `DEFAULT_COLORS`.
      def add_gauge(label : String, value : Number = 0, color : Int32? = nil) : Item
        item = Item.new label, value, color || DEFAULT_COLORS[@gauges.size % DEFAULT_COLORS.size]
        @gauges << item
        request_render
        item
      end

      # Sets a gauge's value by row index.
      def []=(index : Int, value : Number) : Nil
        if item = @gauges[index]?
          item.value = value.to_f
          request_render
        end
      end

      # Sets a gauge's value by label (first match).
      def []=(label : String, value : Number) : Nil
        if item = @gauges.find { |i| i.label == label }
          item.value = value.to_f
          request_render
        end
      end

      def clear : Nil
        @gauges.clear
        request_render
      end

      private def span : Float64
        s = @maximum - @minimum
        s <= 0 ? 1.0 : s
      end

      def render
        self.content = build_content
        super
      end

      private def build_content : String
        cols = awidth - iwidth
        rows = aheight - iheight
        return "" if cols <= 0 || rows <= 0 || @gauges.empty?

        lw = @label_width
        lw = (@gauges.map(&.label.size).max? || 0) if lw <= 0
        lw = lw.clamp(0, Math.max(0, cols - 8)) # leave room for bar + " nn%"

        pct_w = 5 # " 100%"
        bar_cols = cols - lw - 1 - pct_w
        return "" if bar_cols <= 0

        shown = @gauges.first(rows)
        shown.map { |item| gauge_line item, lw, bar_cols, pct_w }.join('\n')
      end

      private def gauge_line(item : Item, lw : Int32, bar_cols : Int32, pct_w : Int32) : String
        pct = ((item.value - @minimum) / span * 100).clamp(0.0, 100.0)
        cells = [] of Char
        colors = [] of String?

        # Label (default style), padded/truncated to the label column.
        label = item.label
        lw.times do |i|
          cells << (label[i]? || ' ')
          colors << nil
        end
        cells << ' '
        colors << nil

        # Bar: sub-cell horizontal block fill in the row's color.
        hexcolor = "##{item.color.to_s(16).rjust(6, '0')}"
        eighths = Graph::Scale.eighths(item.value, @minimum, @maximum, bar_cols)
        bar_cols.times do |c|
          glyph = Graph::Scale.hglyph(eighths, c)
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
