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
    # gl.add_item "cpu", 64
    # gl.add_item "mem", 88, 0xE05050
    # gl.add_item "net", 22
    # gl["mem"] = 91 # update by label
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![GaugeList screenshot](../../tests/widget/gauge_list/gauge_list.5s.apng)
    # <!-- /widget-examples:capture -->
    class GaugeList < Box
      include Mixin::PercentRange

      # One gauge row.
      class Item
        property label : String
        getter value : Float64
        property color : Int32

        # Set by the owning `GaugeList` when the item is added, so a direct
        # `item.value = …` registers with the list's content cache exactly as
        # `list[i] = …` would.
        protected property owner : GaugeList? = nil

        def initialize(@label, value : Number, @color : Int32)
          @value = value.to_f
        end

        # Assigns the value, coercing non-finite input to the owning list's
        # `#minimum` (or `0.0` unowned) since NaN would survive `clamp` and
        # crash the render fiber on `pct.round.to_i`. When the item belongs to
        # a list, bumps that list's version counter and repaints.
        def value=(v : Number) : Float64
          f = v.to_f
          @value = f.finite? ? f : (@owner.try(&.minimum) || 0.0)
          @owner.try &.item_changed
          @value
        end
      end

      # Default per-row colors, cycled by row index.
      DEFAULT_COLORS = [0x40E0D0, 0xE0A040, 0x60C040, 0xD060C0, 0x4090E0, 0xE05050]

      # Shared value range for every gauge.
      getter minimum : Float64
      getter maximum : Float64

      # Sets the lower bound, re-clamping every row's value and the upper
      # bound (carried up rather than inverted) into range. See `#set_range`.
      def minimum=(v : Float64) : Float64
        set_range v, Math.max(v, @maximum)
        @minimum
      end

      # Sets the upper bound, re-clamping every row's value and the lower
      # bound (carried down rather than inverted) into range. See `#set_range`.
      def maximum=(v : Float64) : Float64
        set_range Math.min(v, @minimum), v
        @maximum
      end

      # Sets both bounds at once (Qt's `setRange`). Rejects a non-finite bound
      # outright (NaN survives `max < min` and would poison `percent_of` and
      # the render fiber's `.round.to_i`), keeping the previous valid range.
      # Never stores an inverted range (a max below min collapses to min),
      # re-clamps every gauge row's value into the new range, and repaints on
      # an actual change.
      def set_range(min : Float64, max : Float64) : Nil
        return unless min.finite? && max.finite?
        max = min if max < min
        return if min == @minimum && max == @maximum
        @minimum = min
        @maximum = max
        @gauge_items.each { |g| g.value = g.value.clamp(@minimum, @maximum) }
        @version &+= 1
        request_render
      end

      # Columns reserved for the label column (`nil` = auto from the labels).
      property label_width : Int32?

      @gauge_items : Array(Item) = [] of Item

      def items : Array(Item)
        @gauge_items
      end

      # Bumped whenever the gauge set changes, so the content cache can detect a
      # data change with a cheap integer compare. Mutating an `Item` directly
      # rather than through `#[]=` won't register.
      @version = 0

      def initialize(@minimum : Number = 0.0, @maximum : Number = 100.0,
                     @label_width : Int32? = nil, **box)
        @minimum = @minimum.to_f
        @maximum = @maximum.to_f
        super **box
        self.parse_tags = true
      end

      # Number of gauge rows (Qt's `QListWidget#count`).
      def count : Int32
        @gauge_items.size
      end

      # Appends a gauge and returns it. A `nil` color is auto-assigned from
      # `DEFAULT_COLORS`.
      def add_item(label : String, value : Number = 0, color : Int32? = nil) : Item
        item = Item.new label, sanitize_value(value), color || DEFAULT_COLORS[@gauge_items.size % DEFAULT_COLORS.size]
        item.owner = self
        @gauge_items << item
        @version &+= 1
        request_render
        item
      end

      # Gauge row at *index*, or `nil` when out of range.
      def [](index : Int32) : Item?
        @gauge_items[index]?
      end

      # First gauge row labeled *label*, or `nil` when none matches.
      def [](label : String) : Item?
        @gauge_items.find { |i| i.label == label }
      end

      # Sets a gauge's value by row index.
      def []=(index : Int, value : Number) : Nil
        if item = @gauge_items[index]?
          item.value = sanitize_value(value)
        end
      end

      # Sets a gauge's value by label (first match).
      def []=(label : String, value : Number) : Nil
        if item = @gauge_items.find { |i| i.label == label }
          item.value = sanitize_value(value)
        end
      end

      # Removes the gauge row at *index* (no-op when out of range).
      def remove_item(index : Int32) : Nil
        return unless 0 <= index < @gauge_items.size
        @gauge_items.delete_at index
        @version &+= 1
        request_render
      end

      # Removes the first gauge row labeled *label* (no-op when none matches).
      def remove_item(label : String) : Nil
        if item = @gauge_items.find { |i| i.label == label }
          @gauge_items.delete item
          @version &+= 1
          request_render
        end
      end

      # Registers a direct `Item#value=` mutation with the content cache.
      protected def item_changed : Nil
        @version &+= 1
        request_render
      end

      # Coerces non-finite input to `@minimum` at ingestion: NaN survives every
      # later `clamp` (comparisons with NaN are false) and would crash the
      # render fiber on `pct.round.to_i`.
      private def sanitize_value(value : Number) : Float64
        v = value.to_f
        v.finite? ? v : @minimum
      end

      def clear : Nil
        @gauge_items.clear
        @version &+= 1
        request_render
      end

      # Snapshot of every input `build_content` reads; rebuilding the tagged
      # content allocates per gauge, so skip it while nothing observable changed.
      # Must stay allocation-free per frame. The trailing `glyph_key(style)`
      # covers every input the fill ramp resolves from, so a tier upgrade or CSS
      # `glyphs:` hot-reload rebuilds instead of keeping a stale ramp.
      @content_key : Tuple(Int32, Int32, Int32, Int32, Int32?, Float64, Float64, Int32, {String?, Glyphs::Tier, UInt64})? = nil

      def render
        key = {awidth, aheight, ihorizontal, ivertical, @label_width, @minimum, @maximum, @version,
               glyph_key(style)}
        if key != @content_key
          @content_key = key
          self.content = build_content
        end
        super
      end

      private def build_content : String
        cols = awidth - ihorizontal
        rows = aheight - ivertical
        return "" if cols <= 0 || rows <= 0 || @gauge_items.empty?

        # Size the label column by *display width*, not codepoint count: a wide
        # (CJK/emoji) grapheme is one codepoint but two terminal columns, so
        # `.size` under-measures and the label overflows into the bar.
        lw = @label_width || (@gauge_items.max_of? { |g| str_width(g.label) } || 0)
        lw = lw.clamp(0, Math.max(0, cols - 8)) # leave room for bar + " nn%"

        pct_w = 5 # " 100%"
        bar_cols = cols - lw - 1 - pct_w
        return "" if bar_cols <= 0

        shown = @gauge_items.first(rows)
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
        # the border and wrap the row.
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
        # resolves CSS-first (`glyphs:`), then the registry.
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
