module Crysterm
  class Screen
    # Collection of helper chars for drawing borders and their angles

    @angles = {         # All angles, uniq list
      '\u2518' => true, # '┘'
      '\u2510' => true, # '┐'
      '\u250c' => true, # '┌'
      '\u2514' => true, # '└'
      '\u253c' => true, # '┼'
      '\u251c' => true, # '├'
      '\u2524' => true, # '┤'
      '\u2534' => true, # '┴'
      '\u252c' => true, # '┬'
      '\u2502' => true, # '│'
      '\u2500' => true, # '─'
    }

    @langles = {        # Left angles
      '\u250c' => true, # '┌'
      '\u2514' => true, # '└'
      '\u253c' => true, # '┼'
      '\u251c' => true, # '├'
      '\u2534' => true, # '┴'
      '\u252c' => true, # '┬'
      '\u2500' => true, # '─'
    }

    @uangles = {        # Upper angles
      '\u2510' => true, # '┐'
      '\u250c' => true, # '┌'
      '\u253c' => true, # '┼'
      '\u251c' => true, # '├'
      '\u2524' => true, # '┤'
      '\u252c' => true, # '┬'
      '\u2502' => true, # '│'
    }

    @rangles = {        # Right angles
      '\u2518' => true, # '┘'
      '\u2510' => true, # '┐'
      '\u253c' => true, # '┼'
      '\u2524' => true, # '┤'
      '\u2534' => true, # '┴'
      '\u252c' => true, # '┬'
      '\u2500' => true, # '─'
    }

    @dangles = {        # Down angles
      '\u2518' => true, # '┘'
      '\u2514' => true, # '└'
      '\u253c' => true, # '┼'
      '\u251c' => true, # '├'
      '\u2524' => true, # '┤'
      '\u2534' => true, # '┴'
      '\u2502' => true, # '│'
    }

    # Every ACS angle character can be
    # represented by 4 bits ordered like this:
    # [langle][uangle][rangle][dangle]
    @angle_table = {
       0 => ' ',      # ?         '0000'
       1 => '\u2502', # '│' # ?   '0001'
       2 => '\u2500', # '─' # ??  '0010'
       3 => '\u250c', # '┌'       '0011'
       4 => '\u2502', # '│' # ?   '0100'
       5 => '\u2502', # '│'       '0101'
       6 => '\u2514', # '└'       '0110'
       7 => '\u251c', # '├'       '0111'
       8 => '\u2500', # '─' # ??  '1000'
       9 => '\u2510', # '┐'       '1001'
      10 => '\u2500', # '─' # ??  '1010'
      11 => '\u252c', # '┬'       '1011'
      12 => '\u2518', # '┘'       '1100'
      13 => '\u2524', # '┤'       '1101'
      14 => '\u2534', # '┴'       '1110'
      15 => '\u253c', # '┼'       '1111'
    }

    # Returns appropriate angle char for point (y,x) in `lines`
    def _get_angle(lines, x, y)
      angle = 0
      attr = lines[y][x].attr
      ch = lines[y][x].char

      if (lines[y][x - 1]? && @langles[lines[y][x - 1].char]?)
        if (lines[y][x - 1].attr != attr)
          case @dock_contrast
          when DockContrast::DontDock
            return ch
          when DockContrast::Blend
            lines[y][x].attr = Colors.blend lines[y][x - 1].attr, attr
          end
        end
        angle |= 1 << 3
      end

      if (lines[y - 1]? && @uangles[lines[y - 1][x].char]?)
        if (lines[y - 1][x].attr != attr)
          case @dock_contrast
          when DockContrast::DontDock
            return ch
          when DockContrast::Blend
            lines[y][x].attr = Colors.blend lines[y - 1][x].attr, attr
          end
        end
        angle |= 1 << 2
      end

      if (lines[y][x + 1]? && @rangles[lines[y][x + 1].char]?)
        if (lines[y][x + 1].attr != attr)
          case @dock_contrast
          when DockContrast::DontDock
            return ch
          when DockContrast::Blend
            lines[y][x].attr = Colors.blend lines[y][x + 1].attr, attr
          end
        end
        angle |= 1 << 1
      end

      if (lines[y + 1]? && @dangles[lines[y + 1][x].char]?)
        if (lines[y + 1][x].attr != attr)
          case @dock_contrast
          when DockContrast::DontDock
            return ch
          when DockContrast::Blend
            lines[y][x].attr = Colors.blend lines[y + 1][x].attr, attr
          end
        end
        angle |= 1 << 0
      end

      # Experimental: fixes this situation:
      # +----------+
      #            | <-- empty space here, should be a T angle
      # +-------+  |
      # |       |  |
      # +-------+  |
      # |          |
      # +----------+
      # if uangles[lines[y][x].char]
      #   if lines[y + 1] && @dangles[lines[y + 1][x].char]
      #     case @dock_contrast
      #     when DockContrast::DontDock
      #       if lines[y + 1][x].attr != attr
      #         return ch
      #       end
      #     when DockContrast::Blend
      #       lines[y][x].attr = Colors.blend lines[y + 1][x].attr, attr
      #     end
      #     angle |= 1 << 0
      #   end
      # end

      @angle_table[angle]? || ch
    end
    # end
  end
end
