module Crysterm
  module Methods
    include Crysterm::Macros

    #    # CSI Ps ; Ps H
    #    # Cursor Position [row;column] (default = [1,1]) (CUP).
    #    def cup(row,col)
    #      if !@zero
    #        row = (row || 1) - 1
    #        col = (col || 1) - 1
    #      else
    #        row = row || 0
    #        col = col || 0
    #      end
    #      @x = col
    #      @y = row
    #      _ncoords()
    #      if tput = @tput
    #        put ::Unibilium::Entry::String::Cursor_address, row, col
    #      else
    #        _write("\x1b[" + (row + 1).to_s + ";" + (col + 1).to_s + "H")
    #      end
    #    end
    #    #alias_previous cup, pos, cursor_address, cursor_pos

    # CSI > Ps; Ps m
    #   Set or reset resource-values used by xterm to decide whether
    #   to construct escape sequences holding information about the
    #   modifiers pressed with a given key.  The first parameter iden-
    #   tifies the resource to set/reset.  The second parameter is the
    #   value to assign to the resource.  If the second parameter is
    #   omitted, the resource is reset to its initial value.
    #     Ps = 1  -> modifyCursorKeys.
    #     Ps = 2  -> modifyFunctionKeys.
    #     Ps = 4  -> modifyOtherKeys.
    #   If no parameters are given, all resources are reset to their
    #   initial values.
    def set_resources(*arguments)
      _write("\x1b[>" + arguments.join(';') + 'm')
    end

    # CSI > Ps n
    #   Disable modifiers which may be enabled via the CSI > Ps; Ps m
    #   sequence.  This corresponds to a resource value of "-1", which
    #   cannot be set with the other sequence.  The parameter identi-
    #   fies the resource to be disabled:
    #     Ps = 1  -> modifyCursorKeys.
    #     Ps = 2  -> modifyFunctionKeys.
    #     Ps = 4  -> modifyOtherKeys.
    #   If the parameter is omitted, modifyFunctionKeys is disabled.
    #   When modifyFunctionKeys is disabled, xterm uses the modifier
    #   keys to make an extended sequence of functions rather than
    #   adding a parameter to each function key to denote the modi-
    #   fiers.
    def disable_modifiers(param = nil)
      _write("\x1b[>" + (param || "") + 'n')
    end

    # CSI Ps " q
    #   Select character protection attribute (DECSCA).  Valid values
    #   for the parameter:
    #     Ps = 0  -> DECSED and DECSEL can erase (default).
    #     Ps = 1  -> DECSED and DECSEL cannot erase.
    #     Ps = 2  -> DECSED and DECSEL can erase.
    def set_char_protection_attr(param = nil)
      _write("\x1b[" + (param || 0) + "\"q")
    end

    alias_previous decsca

    # CSI ? Pm r
    #   Restore DEC Private Mode Values.  The value of Ps previously
    #   saved is restored.  Ps values are the same as for DECSET.
    def restore_private_values(*arguments)
      _write("\x1b[?" + arguments.join(';') + 'r')
    end

    # CSI ? Pm s
    #   Save DEC Private Mode Values.  Ps values are the same as for
    #   DECSET.
    def save_private_values(*arguments)
      _write("\x1b[?" + arguments.join(';') + 's')
    end

    # CSI Ps x  Request Terminal Parameters (DECREQTPARM).
    #   if Ps is a "0" (default) or "1", and xterm is emulating VT100,
    #   the control sequence elicits a response of the same form whose
    #   parameters describe the terminal:
    #     Ps -> the given Ps incremented by 2.
    #     Pn = 1  <- no parity.
    #     Pn = 1  <- eight bits.
    #     Pn = 1  <- 2  8  transmit 38.4k baud.
    #     Pn = 1  <- 2  8  receive 38.4k baud.
    #     Pn = 1  <- clock multiplier.
    #     Pn = 0  <- STP flags.
    def request_parameters(param = nil)
      _write("\x1b[" + (param || 0) + "x")
    end

    alias_previous decreqtparm

    #
    # List of less used ones:
    #

    def mc5
      has_and_put("mc5") || has_and_put("mc", "5")
    end

    alias_previous prtr_on, po

    def mc4
      has_and_put("mc4") || has_and_put("mc", "4")
    end

    alias_previous prtr_off, pf

    def mc5p
      has_and_put("mc5p") || has_and_put("mc", "?5")
    end

    alias_previous prtr_non, pO
  end
end

#    # TODO - waiting for functional response()
#    # getCursorColor, getTextParams
#
#
#    # ESC D Index (IND is 0x84).
#    def index
#      @y+=1
#      _ncoords
#      has_and_put("ind") : _write("\x1bD")
#    end
#    alias_previous ind
#
#    # ESC M Reverse Index (RI is 0x8d).
#    def reverse_index
#      @y-=1
#      _ncoords
#      has_and_put("ri") : _write("\x1bM")
#    end
#    alias_previous ri, reverse
#
#    # TODO sendDeviceAttributes
#
#    # CSI > Ps; Ps m
#    #   Set or reset resource-values used by xterm to decide whether
#    #   to construct escape sequences holding information about the
#    #   modifiers pressed with a given key.  The first parameter iden-
#    #   tifies the resource to set/reset.  The second parameter is the
#    #   value to assign to the resource.  If the second parameter is
#    #   omitted, the resource is reset to its initial value.
#    #     Ps = 1  -> modifyCursorKeys.
#    #     Ps = 2  -> modifyFunctionKeys.
#    #     Ps = 4  -> modifyOtherKeys.
#    #   If no parameters are given, all resources are reset to their
#    #   initial values.
#    def set_resources(*arguments)
#      _write("\x1b[>" + arguments.join(';') + 'm')
#    end
#
#    # CSI > Ps n
#    #   Disable modifiers which may be enabled via the CSI > Ps; Ps m
#    #   sequence.  This corresponds to a resource value of "-1", which
#    #   cannot be set with the other sequence.  The parameter identi-
#    #   fies the resource to be disabled:
#    #     Ps = 1  -> modifyCursorKeys.
#    #     Ps = 2  -> modifyFunctionKeys.
#    #     Ps = 4  -> modifyOtherKeys.
#    #   If the parameter is omitted, modifyFunctionKeys is disabled.
#    #   When modifyFunctionKeys is disabled, xterm uses the modifier
#    #   keys to make an extended sequence of functions rather than
#    #   adding a parameter to each function key to denote the modi-
#    #   fiers.
#    def disable_modifiers(param=nil)
#      _write("\x1b[>" + param.to_s + 'n')
#    end
#
#    # CSI Ps " q
#    #   Select character protection attribute (DECSCA).  Valid values
#    #   for the parameter:
#    #     Ps = 0  -> DECSED and DECSEL can erase (default).
#    #     Ps = 1  -> DECSED and DECSEL cannot erase.
#    #     Ps = 2  -> DECSED and DECSEL can erase.
#    def set_char_protection_attr(param=0)
#      _write("\x1b[" + param.to_s + "\"q")
#    end
#    alias_previous decsca
#
#    # CSI ? Pm r
#    #   Restore DEC Private Mode Values.  The value of Ps previously
#    #   saved is restored.  Ps values are the same as for DECSET.
#    def restore_private_values(*arguments)
#      _write("\x1b[?" + arguments.join(';') + 'r')
#    end
#
#    # CSI ? Pm s
#    #   Save DEC Private Mode Values.  Ps values are the same as for
#    #   DECSET.
#    def save_private_values(*arguments)
#      _write("\x1b[?" + arguments.join(';') + 's')
#    end
#
#    # TODO getWindowSize manipulateWindow
#
#    # CSI Ps x  Request Terminal Parameters (DECREQTPARM).
#    #   if Ps is a "0" (default) or "1", and xterm is emulating VT100,
#    #   the control sequence elicits a response of the same form whose
#    #   parameters describe the terminal:
#    #     Ps -> the given Ps incremented by 2.
#    #     Pn = 1  <- no parity.
#    #     Pn = 1  <- eight bits.
#    #     Pn = 1  <- 2  8  transmit 38.4k baud.
#    #     Pn = 1  <- 2  8  receive 38.4k baud.
#    #     Pn = 1  <- clock multiplier.
#    #     Pn = 0  <- STP flags.
#    def request_parameters(param=0)
#      _write("\x1b[" + param.to_s + "x")
#    end
#    alias_previous decreqtparm

#
#    # TODO decrqlp
#
#  end
# end
