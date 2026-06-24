require "../box"
require "./canvas"

module Crysterm
  class Widget
    module Graph
      # A geographic map, modeled after Qt Location's `Map` rather than
      # blessed-contrib's `map`. Coastlines are drawn on a backend-agnostic
      # `Graph::Canvas` (sixel/kitty where available, else braille), and markers
      # are placed by geographic coordinate and drawn as terminal glyphs on top —
      # the same "outline = pixels, markers/labels = text" split as `LineChart`.
      #
      # The visible area is a longitude/latitude window (`#min_lon`..`#max_lon`,
      # `#min_lat`..`#max_lat`) under a plain equirectangular projection; the
      # default excludes Antarctica. Use `#look_at` (à la `Map.center` +
      # `zoomLevel`) or set the bounds directly.
      #
      # Qt-style pieces:
      # * `Marker` — a `QGeoCoordinate`-placed item with a glyph, color and label;
      #   add with `#add_marker latitude:, longitude:, …` (like a `MapQuickItem`).
      # * `#look_at(lat, lon, span_lat:, span_lon:)` — recenters the view.
      #
      # Coastline data is the public-domain gnuplot `world.dat`, embedded at
      # compile time.
      #
      # ```
      # m = Widget::Graph::Map.new parent: s, width: 80, height: 24,
      #   style: Style.new(border: true)
      # m.add_marker latitude: 40.71, longitude: -74.0, label: "NYC", color: 0xE05050
      # m.add_marker latitude: 35.68, longitude: 139.69, label: "Tokyo", color: 0x40E0D0
      # m.refresh
      # ```
      class Map < Box
        # A coordinate-placed marker (Qt's `MapQuickItem`).
        struct Marker
          property latitude : Float64
          property longitude : Float64
          property char : Char
          property color : Int32
          property label : String?

          def initialize(@latitude, @longitude, @char = '●', @color = 0xE05050, @label = nil)
          end
        end

        # Embedded coastline polylines (`{lon, lat}` points), grouped into the
        # segments `world.dat` separates with blank lines. Parsed once at load.
        WORLD = begin
          raw = {{ read_file("#{__DIR__}/world.dat") }}
          segments = [] of Array(Tuple(Float64, Float64))
          current = [] of Tuple(Float64, Float64)
          raw.each_line do |line|
            line = line.strip
            if line.empty? || line.starts_with?('#')
              segments << current unless current.empty?
              current = [] of Tuple(Float64, Float64)
              next
            end
            parts = line.split
            next unless parts.size >= 2
            lon = parts[0].to_f?
            lat = parts[1].to_f?
            current << {lon, lat} if lon && lat
          end
          segments << current unless current.empty?
          segments
        end

        # Viewport in degrees (equirectangular). Defaults to a populated-world view
        # (Antarctica trimmed).
        property min_lon : Float64
        property max_lon : Float64
        property min_lat : Float64
        property max_lat : Float64

        # Coastline color.
        property land_color : Int32

        # Optional lat/lon grid.
        property? show_graticule : Bool
        property graticule_color : Int32
        property graticule_step : Float64

        getter markers : Array(Marker) = [] of Marker

        @canvas : Canvas?

        # The Canvas the coastlines are drawn on.
        def canvas : Canvas
          @canvas.not_nil!
        end

        def initialize(
          @min_lon : Float64 = -180.0,
          @max_lon : Float64 = 180.0,
          @min_lat : Float64 = -60.0,
          @max_lat : Float64 = 85.0,
          @land_color : Int32 = 0x4E9A50,
          @show_graticule : Bool = false,
          @graticule_color : Int32 = 0x283038,
          @graticule_step : Float64 = 30.0,
          type : Media::Type? = nil,
          glyph_mode : Media::Glyph::Mode = Media::Glyph::Mode::Braille,
          **box,
        )
          super **box
          cv = Canvas.new parent: self, type: type, glyph_mode: glyph_mode,
            top: 0, left: 0, right: 0, bottom: 0
          cv.on_paint { |p| paint_map p }
          @canvas = cv
        end

        # Adds a marker at a geographic coordinate (Qt's `MapQuickItem`).
        def add_marker(latitude : Number, longitude : Number, char : Char = '●',
                       color : Int32 = 0xE05050, label : String? = nil) : Marker
          m = Marker.new latitude.to_f, longitude.to_f, char, color, label
          @markers << m
          request_render
          m
        end

        def clear_markers : Nil
          @markers.clear
          request_render
        end

        # Recenters the view on (lat, lon) with the given degree spans (Qt's
        # `center` + `zoomLevel`, expressed as a span).
        def look_at(lat : Number, lon : Number, span_lat : Number = 120, span_lon : Number = 360) : Nil
          @min_lat = lat.to_f - span_lat.to_f / 2
          @max_lat = lat.to_f + span_lat.to_f / 2
          @min_lon = lon.to_f - span_lon.to_f / 2
          @max_lon = lon.to_f + span_lon.to_f / 2
          request_render
        end

        def refresh : Nil
          request_render
        end

        def render(with_children = true)
          super
          draw_markers
        end

        # --- coastlines (drawn on the Canvas) ---------------------------------

        private def paint_map(p : Painter) : Nil
          # Equirectangular window with latitude flipped (north up): negative
          # height maps max_lat→top.
          p.set_window @min_lon, @max_lat, @max_lon - @min_lon, @min_lat - @max_lat

          if show_graticule?
            p.pen = @graticule_color
            lon = (@min_lon / @graticule_step).ceil * @graticule_step
            while lon <= @max_lon
              p.draw_line lon, @min_lat, lon, @max_lat
              lon += @graticule_step
            end
            lat = (@min_lat / @graticule_step).ceil * @graticule_step
            while lat <= @max_lat
              p.draw_line @min_lon, lat, @max_lon, lat
              lat += @graticule_step
            end
          end

          p.pen = @land_color
          WORLD.each do |segment|
            (1...segment.size).each do |i|
              a = segment[i - 1]
              b = segment[i]
              # Skip dateline-wrap jumps (a single segment occasionally straddles
              # ±180), which would otherwise draw a line clear across the map.
              next if (a[0] - b[0]).abs > 180.0
              p.draw_line a[0], a[1], b[0], b[1]
            end
          end
        end

        # --- markers (terminal glyphs over the map) ---------------------------

        private def draw_markers : Nil
          return if @markers.empty?
          lp = @lpos || return
          xi = lp.xi + ileft
          xl = lp.xl - iright
          yi = lp.yi + itop
          yl = lp.yl - ibottom
          w = xl - xi
          h = yl - yi
          return if w <= 0 || h <= 0

          @markers.each do |m|
            next if m.longitude < @min_lon || m.longitude > @max_lon
            next if m.latitude < @min_lat || m.latitude > @max_lat
            fx = (m.longitude - @min_lon) / (@max_lon - @min_lon)
            fy = (@max_lat - m.latitude) / (@max_lat - @min_lat)
            cx = xi + (fx * (w - 1)).round.to_i
            cy = yi + (fy * (h - 1)).round.to_i
            put_cell cx, cy, m.char, marker_attr(m.color), xi, xl
            if (label = m.label)
              put_text cx + 1, cy, label, marker_attr(m.color), xi, xl
            end
          end
        end

        @attr_cache = {} of Int32 => Int64

        private def marker_attr(color : Int32) : Int64
          @attr_cache[color] ||= sattr(style, color, style.bg)
        end

        private def put_cell(x : Int32, y : Int32, ch : Char, attr : Int64, lo : Int32, hi : Int32) : Nil
          return if x < lo || x >= hi
          line = screen.lines[y]?
          return unless line
          if cell = line[x]?
            cell.char = ch
            cell.attr = attr
            line.dirty = true
          end
        end

        private def put_text(x : Int32, y : Int32, text : String, attr : Int64, lo : Int32, hi : Int32) : Nil
          line = screen.lines[y]?
          return unless line
          text.each_char_with_index do |ch, i|
            cx = x + i
            next if cx < lo || cx >= hi
            if cell = line[cx]?
              cell.char = ch
              cell.attr = attr
            end
          end
          line.dirty = true
        end
      end
    end
  end
end
