require "./box"
require "./graph/scale"
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

        # This row's last built tagged-content string, and the `{value, color,
        # label}` it was built for. Lives on the *item* (not in a list-indexed
        # array) so a removal/reorder can't hand one row's cache to another item:
        # the cache travels with the identity it describes.
        #
        # `label` is compared by VALUE because `#label`/`#color` are plain
        # settable properties that don't notify the list. The remaining
        # `gauge_line` inputs are list-wide (label-column width, bar width,
        # range, fill ramp, unicode mode) and are keyed by `GaugeList`'s
        # `@row_list_key`, which clears every item's cache when it changes.
        protected property row_cache : String? = nil
        protected property row_key : Tuple(Float64, Int32, String)? = nil

        def initialize(@label, value : Number, @color : Int32)
          @value = value.to_f
        end

        # Assigns the value, coercing non-finite input to the owning list's
        # `#minimum` (or `0.0` unowned) since NaN would survive `clamp` and
        # crash the render fiber on `pct.round.to_i`. When the item belongs to
        # a list, bumps that list's version counter and repaints.
        def value=(v : Number) : Float64
          f = v.to_f
          @value = @owner.try(&.sanitize_value(f, @owner.try(&.minimum) || 0.0)) || 0.0
          @owner.try &.item_changed
          @value
        end
      end

      # Default per-row colors, cycled by row index.
      DEFAULT_COLORS = [0x40E0D0, 0xE0A040, 0x60C040, 0xD060C0, 0x4090E0, 0xE05050]

      # Shared value range for every gauge.
      getter minimum : Float64
      getter maximum : Float64

      # Sets both bounds at once (Qt's `setRange`). Rejects a non-finite bound
      # outright (NaN survives `max < min` and would poison `percent_of` and
      # the render fiber's `.round.to_i`), keeping the previous valid range.
      # Never stores an inverted range (a max below min collapses to min),
      # re-clamps every gauge row's value into the new range, and repaints on
      # an actual change.
      def set_range(min : Float64, max : Float64) : Nil
        return unless nm = normalize_range(min, max)
        @minimum, @maximum = nm
        @gauge_items.each { |g| g.value = g.value.clamp(@minimum, @maximum) }
        @version &+= 1
        request_render
      end

      # Columns reserved for the label column (`nil` = auto from the labels).
      getter label_width : Int32?

      # Assigns `#label_width` and schedules a repaint: the content cache's key
      # includes `@label_width` so a bare `property` setter's change would only
      # take effect on some later, unrelated frame.
      repaint_property label_width, Int32?

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
        # A non-finite bound would bypass `#set_range`'s guard and poison
        # `#percent_of`, crashing the render fiber on `pct.round.to_i`.
        @minimum, @maximum = sanitize_range(@minimum.to_f, @maximum.to_f)
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
        item = Item.new(label, sanitize_value(value.to_f), color || DEFAULT_COLORS[@gauge_items.size % DEFAULT_COLORS.size])
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
          item.value = sanitize_value(value.to_f)
        end
      end

      # Sets a gauge's value by label (first match).
      def []=(label : String, value : Number) : Nil
        if item = @gauge_items.find { |i| i.label == label }
          item.value = sanitize_value(value.to_f)
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

      # Everything `#gauge_line` reads that is *not* per-item: the label-column
      # and bar widths, the shared range, the unicode mode the label is fitted
      # with, and the fill-ramp inputs. While this holds, a row whose
      # `{value, color, label}` is unchanged renders byte-identically, so its
      # `Item#row_cache` can be reused instead of rebuilt — a value change on
      # one gauge no longer rebuilds every other row's tagged string.
      @row_list_key : Tuple(Int32, Int32, Float64, Float64, Bool, {String?, Glyphs::Tier, UInt64})? = nil

      def render(with_children = true)
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

        # The fill ramp resolves CSS-first (`glyphs:`), then the registry — one
        # resolution for the whole list rather than one per row.
        ramp = glyph_seq(Glyphs::SeqRole::ScaleHorizontal, style, cells: true)

        # A change to any list-wide `#gauge_line` input invalidates every row's
        # memo; per-item changes are caught by the `{value, color, label}` key.
        list_key = {lw, bar_cols, @minimum, @maximum, full_unicode?, glyph_key(style)}
        if @row_list_key != list_key
          @row_list_key = list_key
          @gauge_items.each(&.row_key=(nil))
        end

        shown = @gauge_items.first(rows)
        shown.map { |item| row_for item, lw, bar_cols, pct_w, ramp }.join('\n')
      end

      # `#gauge_line` memoized on the item: rebuilds only when this row's own
      # `{value, color, label}` changed (list-wide inputs having been checked by
      # the caller).
      private def row_for(item : Item, lw : Int32, bar_cols : Int32, pct_w : Int32, ramp : Array(Char)) : String
        key = {item.value, item.color, item.label}
        if item.row_key == key && (cached = item.row_cache)
          return cached
        end
        row = gauge_line item, lw, bar_cols, pct_w, ramp
        item.row_key = key
        item.row_cache = row
        row
      end

      private def gauge_line(item : Item, lw : Int32, bar_cols : Int32, pct_w : Int32, ramp : Array(Char)) : String
        pct = percent_of item.value
        # Row is exactly `lw + 1 (gap) + bar_cols + pct_w` display columns wide;
        # size it up front (these are rebuilt every animated frame) and write by
        # index — the blanks of the label padding and the inter-column gap are
        # already in place. A wide (CJK/emoji) label grapheme spans 2 columns but
        # occupies only ONE slot, so the row can end up that much SHORTER than
        # `cap` in slots while keeping its column width; the unused tail is
        # truncated below.
        cap = lw + 1 + bar_cols + pct_w
        cells = Array(Char).new(cap, ' ')
        colors = Array(String?).new(cap, nil)

        # Label (default style), fit to exactly `lw` *display columns* so a wide
        # grapheme (1 codepoint, 2 columns) doesn't push the bar/percentage past
        # the border and wrap the row.
        i = 0
        used = 0
        item.label.each_char do |ch|
          cw = str_width(ch.to_s)
          break if used + cw > lw
          cells[i] = ch
          i += 1
          used += cw
        end
        # Label padding (`lw - used` blanks) plus the one-column gap: already
        # `' '`/`nil`, so only the cursor moves.
        i += lw - used + 1

        # Bar: sub-cell horizontal block fill in the row's color.
        eighths = Graph::Scale.eighths(item.value, @minimum, @maximum, bar_cols)
        Graph::Scale.fill_ramp cells, colors, ramp, eighths, Colors.hex(item.color), i, bar_cols
        i += bar_cols

        # Percentage (default style), right-aligned in its field. `percent_of`
        # clamps to `0..100`, so the text never exceeds `pct_w` columns.
        "#{pct.round.to_i}%".rjust(pct_w).each_char do |ch|
          break if i >= cap
          cells[i] = ch
          i += 1
        end

        if i < cap
          cells.truncate 0, i
          colors.truncate 0, i
        end
        Graph::Scale.tagged_row(cells, colors)
      end
    end
  end
end
