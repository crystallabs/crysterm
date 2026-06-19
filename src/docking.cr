module Crysterm
  # Reusable "docking" component.
  #
  # Docking takes the points where line-drawing characters cross or meet
  # (e.g. two box borders touching, or `Widget::Line`s crossing) and replaces
  # the overlapping/adjacent characters with a single character that joins them
  # seamlessly. For example, these border-overlapped elements:
  #
  #     ┌─────────┌─────────┐
  #     │ box1    │ box2    │
  #     └─────────└─────────┘
  #
  # become:
  #
  #     ┌─────────┬─────────┐
  #     │ box1    │ box2    │
  #     └─────────┴─────────┘
  #
  # The component is intentionally agnostic about *what* produced the
  # characters. It operates purely on the in-memory grid of cells (`lines`),
  # so the same logic serves borders, `Line` widgets, and anything else that
  # draws with the box-drawing characters in `ANGLES`.
  #
  # Callers collect the set of rows ("stops") on which line-drawing characters
  # were emitted (only rows with *horizontal* segments need to be collected;
  # vertical segments are picked up when a horizontal stop crosses them), then
  # call `dock` to re-evaluate every relevant cell on those rows. See
  # `Screen#_dock` and `Widget#register_dock_stops` for the callers.
  module Docking
    extend self

    # Collection of helper chars for drawing borders and their angles.

    # Left, top, right, and bottom angles
    L_ANGLES = {'┌', '└', '┼', '├', '┴', '┬', '─'}
    U_ANGLES = {'┐', '┌', '┼', '├', '┤', '┬', '│'}
    R_ANGLES = {'┘', '┐', '┼', '┤', '┴', '┬', '─'}
    D_ANGLES = {'┘', '└', '┼', '├', '┤', '┴', '│'}

    # All angles, uniq list
    ANGLES = {'┘', '┐', '┌', '└', '┼', '├', '┤', '┴', '┬', '│', '─'}

    # Every ACS angle character can be
    # represented by 4 bits ordered like this:
    # [langle][uangle][rangle][dangle]
    ANGLE_TABLE = {
       0 => ' ', # ?   '0000'
       1 => '│', # ?   '0001'
       2 => '─', # ??  '0010'
       3 => '┌', #     '0011'
       4 => '│', # ?   '0100'
       5 => '│', #     '0101'
       6 => '└', #     '0110'
       7 => '├', #     '0111'
       8 => '─', # ??  '1000'
       9 => '┐', #     '1001'
      10 => '─', # ??  '1010'
      11 => '┬', #     '1011'
      12 => '┘', #     '1100'
      13 => '┤', #     '1101'
      14 => '┴', #     '1110'
      15 => '┼', #     '1111'
    }

    BITWISE_L_ANGLE = 1 << 3
    BITWISE_U_ANGLE = 1 << 2
    BITWISE_R_ANGLE = 1 << 1
    BITWISE_D_ANGLE = 1 << 0

    # Re-evaluates and docks every angle character found on each of the `stops`
    # rows of `lines`. `width` is the number of columns to scan per row, and
    # `dock_contrast` controls how cells with differing colors/attributes are
    # treated (see `DockContrast`).
    def dock(lines, stops, width, dock_contrast : DockContrast)
      stops.keys.map(&.to_i).sort!.each do |y|
        next unless lines[y]?

        width.times do |x|
          ch = lines[y][x].char
          if ANGLES.includes? ch
            lines[y][x].char = angle_at lines, x, y, dock_contrast
            lines[y].dirty = true
          end
        end
      end
    end

    # Returns the appropriate joining/angle character for the cell at (`x`, `y`)
    # in `lines`, based on which of its four neighbors also hold line-drawing
    # characters. `dock_contrast` decides what happens when a neighbor's
    # attribute differs from this cell's.
    def angle_at(lines, x, y, dock_contrast : DockContrast)
      angle = 0
      attr = lines[y][x].attr
      ch = lines[y][x].char

      if x > 0 && lines[y][x - 1]? && L_ANGLES.includes? lines[y][x - 1].char
        if lines[y][x - 1].attr != attr
          case dock_contrast
          when DockContrast::DontDock
            return ch
          when DockContrast::Blend
            lines[y][x].attr = Colors.blend lines[y][x - 1].attr, attr
            # when DockContrast::Ignore
            #  Note: ::Ignore needs no custom handler/code; it works as-is.
          end
        end
        angle |= BITWISE_L_ANGLE
      end

      if y > 0 && lines[y - 1]? && U_ANGLES.includes? lines[y - 1][x].char
        if lines[y - 1][x].attr != attr
          case dock_contrast
          when DockContrast::DontDock
            return ch
          when DockContrast::Blend
            lines[y][x].attr = Colors.blend lines[y - 1][x].attr, attr
            # when DockContrast::Ignore
            #  Note: ::Ignore needs no custom handler/code; it works as-is.
          end
        end
        angle |= BITWISE_U_ANGLE
      end

      if lines[y][x + 1]? && R_ANGLES.includes? lines[y][x + 1].char
        if lines[y][x + 1].attr != attr
          case dock_contrast
          when DockContrast::DontDock
            return ch
          when DockContrast::Blend
            lines[y][x].attr = Colors.blend lines[y][x + 1].attr, attr
            # when DockContrast::Ignore
            #  Note: ::Ignore needs no custom handler/code; it works as-is.
          end
        end
        angle |= BITWISE_R_ANGLE
      end

      if lines[y + 1]? && D_ANGLES.includes? lines[y + 1][x].char
        if lines[y + 1][x].attr != attr
          case dock_contrast
          when DockContrast::DontDock
            return ch
          when DockContrast::Blend
            lines[y][x].attr = Colors.blend lines[y + 1][x].attr, attr
            # when DockContrast::Ignore
            #  Note: ::Ignore needs no custom handler/code; it works as-is.
          end
        end
        angle |= BITWISE_D_ANGLE
      end

      # Experimental: fixes this situation:
      # +----------+
      #            | <-- empty space here, should be a T angle
      # +-------+  |
      # |       |  |
      # +-------+  |
      # |          |
      # +----------+
      # if U_ANGLES.includes? lines[y][x].char
      #  if lines[y + 1] && D_ANGLES.includes? lines[y + 1][x].char
      #    case dock_contrast
      #    when DockContrast::DontDock
      #      if lines[y + 1][x].attr != attr
      #        return ch
      #      end
      #    when DockContrast::Blend
      #      lines[y][x].attr = Colors.blend lines[y + 1][x].attr, attr
      #    end
      #    angle |= BITWISE_D_ANGLE
      #  end
      # end

      ANGLE_TABLE[angle]? || ch
    end
  end
end
