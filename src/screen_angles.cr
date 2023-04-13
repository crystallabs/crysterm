module Crysterm
  class Screen
    # Collection of helper chars for drawing borders and their angles

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

    # Returns appropriate angle char for point (y,x) in `lines`
    #
    # To operate, needs `lines` (the 2d array of cells), and (y,x) point
    # you're asking for.
    def _get_angle(lines, x, y)
      angle = 0
      attr = lines[y][x].attr
      ch = lines[y][x].char

      if lines[y][x - 1]? && L_ANGLES.includes? lines[y][x - 1].char
        if (lines[y][x - 1].attr != attr)
          case @dock_contrast
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

      if lines[y - 1]? && U_ANGLES.includes? lines[y - 1][x].char
        if (lines[y - 1][x].attr != attr)
          case @dock_contrast
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
        if (lines[y][x + 1].attr != attr)
          case @dock_contrast
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
        if (lines[y + 1][x].attr != attr)
          case @dock_contrast
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
      #    case @dock_contrast
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
