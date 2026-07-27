module Crysterm
  # Text counterpart to `Capture`: serializes a region of the rendered cell
  # buffer into a deterministic, human-readable, diffable form — the exact
  # glyphs plus a run-length summary of non-default cell attributes.
  #
  # Enables golden testing without a comparison engine: commit a `.dump` next
  # to the example's `.png`/`.apng` and later changes show up as a localized
  # diff. The cell buffer is fully deterministic, so identical behavior
  # reproduces byte-for-byte identical text.
  module Dump
    # Serializes cells in the region `[xi,xl) x [yi,yl)` of *window*'s composited
    # buffer. Two sections:
    #
    #   * **text** — one line per row, each wrapped in `|...|` so trailing spaces
    #     and width changes are visible in a diff. Wide (2-column) graphemes emit
    #     their cluster once; their continuation cell is skipped.
    #   * **attrs** — for each row that has any non-default cell, a run-length
    #     list `col0-colN:fg/bg+flags` (columns relative to `xi`). Rows that are
    #     entirely the window default attribute are omitted, so a plain
    #     monochrome widget has an empty attrs section.
    def self.text(window : Window, xi : Int32, xl : Int32, yi : Int32, yl : Int32) : String
      w = xl - xi
      h = yl - yi
      String.build do |io|
        io << "w=" << w << " h=" << h << '\n'
        io << '+' << ("-" * w) << "+\n"

        rows = Array(String::Builder).new(h) { String::Builder.new }
        window.each_content_cell(xi, xl, yi, yl) do |cell, rx, ry|
          g = cell.grapheme
          # The artificial cursor lives only in the flushed output stream, so
          # overlay its glyph here or a dump would silently omit it.
          if (ov = window.capture_cursor_overlay(rx + xi, ry + yi)) && (och = ov[1])
            g = och.to_s
          end
          rows[ry] << (g.empty? ? " " : g)
        end
        rows.each { |rb| io << '|' << rb.to_s << "|\n" }
        io << '+' << ("-" * w) << "+\n"

        dfl = window.default_attr
        attr_lines = String.build do |a|
          (yi...yl).each do |y|
            line = window.lines[y]
            runs = String.build do |r|
              x = xi
              while x < xl
                attr = attr_at(window, line, x, y)
                start = x
                x += 1
                while x < xl && attr_at(window, line, x, y) == attr
                  x += 1
                end
                next if attr == dfl
                r << ' ' unless r.empty?
                r << (start - xi) << '-' << (x - 1 - xi) << ':' << attr_s(attr)
              end
            end
            next if runs.empty?
            a << 'y' << (y - yi) << ": " << runs << '\n'
          end
        end
        unless attr_lines.empty?
          io << "attrs:\n" << attr_lines
        end
      end
    end

    # Cell attr with the artificial-cursor overlay applied (see
    # `Window#capture_cursor_overlay`), so the attrs section shows the cursor
    # cell exactly as the terminal does.
    private def self.attr_at(window : Window, line, x : Int32, y : Int32) : Int64
      window.capture_cursor_overlay(x, y).try(&.[0]) || line[x].attr
    end

    # `fg/bg` plus a `+flag` suffix for each set style flag, e.g. `#c0caf5/def+b`.
    def self.attr_s(attr : Int64) : String
      String.build do |io|
        io << color_s(Attr.fg(attr)) << '/' << color_s(Attr.bg(attr))
        flags = Attr.flags(attr)
        io << "+b" if flags & Attr::BOLD != 0
        io << "+u" if flags & Attr::UNDERLINE != 0
        io << "+k" if flags & Attr::BLINK != 0
        io << "+r" if flags & Attr::REVERSE != 0
        io << "+x" if flags & Attr::INVISIBLE != 0
        io << "+i" if flags & Attr::ITALIC != 0
        io << "+s" if flags & Attr::STRIKE != 0
      end
    end

    # `def` for the terminal default, else `#rrggbb`.
    private def self.color_s(field : Int64) : String
      c = Attr.unpack_color(field)
      c < 0 ? "def" : ("#%06x" % c)
    end
  end
end
