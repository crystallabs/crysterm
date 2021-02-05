module Crysterm
  # Represents a screen. `Screen` and `Element` are two lowest-level classes after `EventEmitter` and `Node`.
  module Widget
    class Screen < Node
      module Angles
        @angles = {
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

        @langles = {
          '\u250c' => true, # '┌'
          '\u2514' => true, # '└'
          '\u253c' => true, # '┼'
          '\u251c' => true, # '├'
          '\u2534' => true, # '┴'
          '\u252c' => true, # '┬'
          '\u2500' => true, # '─'
        }

        @uangles = {
          '\u2510' => true, # '┐'
          '\u250c' => true, # '┌'
          '\u253c' => true, # '┼'
          '\u251c' => true, # '├'
          '\u2524' => true, # '┤'
          '\u252c' => true, # '┬'
          '\u2502' => true, # '│'
        }

        @rangles = {
          '\u2518' => true, # '┘'
          '\u2510' => true, # '┐'
          '\u253c' => true, # '┼'
          '\u2524' => true, # '┤'
          '\u2534' => true, # '┴'
          '\u252c' => true, # '┬'
          '\u2500' => true, # '─'
        }

        @dangles = {
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
           0 => ' ',      # ?               "0000"
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

        def _get_angle(lines, x, y)
          angle = 0
          attr = lines[y][x].attr
          ch = lines[y][x].char

          if (lines[y][x - 1]? && @langles[lines[y][x - 1].char]?)
            if (!@ignore_dock_contrast)
              if (lines[y][x - 1].attr != attr)
                return ch
              end
            end
            angle |= 1 << 3
          end

          if (lines[y - 1]? && @uangles[lines[y - 1][x].char]?)
            if (!@ignore_dock_contrast)
              if (lines[y - 1][x].attr != attr)
                return ch
              end
            end
            angle |= 1 << 2
          end

          if (lines[y][x + 1]? && @rangles[lines[y][x + 1].char]?)
            if (!@ignore_dock_contrast)
              if (lines[y][x + 1].attr != attr)
                return ch
              end
            end
            angle |= 1 << 1
          end

          if (lines[y + 1]? && @dangles[lines[y + 1][x].char]?)
            if (!@ignore_dock_contrast)
              if (lines[y + 1][x].attr != attr)
                return ch
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
          # if (uangles[lines[y][x][1]])
          #   if (lines[y + 1] && cdangles[lines[y + 1][x][1]])
          #     if (!@options.ignoreDockContrast)
          #       if (lines[y + 1][x][0] != attr) return ch
          #     }
          #     angle |= 1 << 0
          #   }
          # }

          @angle_table[angle]? || ch
        end
      end
    end
  end
end
