module Crysterm
  class Screen
    # Output color depth. This is the only attribute/SGR-adjacent state that
    # genuinely belongs to the device; the SGR<->attr engine itself is the pure
    # `Crysterm::SGR` module (src/sgr.cr), and the packed attribute word is
    # `Crysterm::Attr` (src/attr.cr).

    # Number of colors the output terminal supports (1 for monochrome, 8, 16,
    # 256, or 16_777_216 for TrueColor). Drives color reduction at output time.
    # The terminal-detected count is overridden by the `colors.depth` config
    # option and the `NO_COLOR` / `FORCE_COLOR` / `CLICOLOR[_FORCE]` env vars.
    #
    # Computed fresh on each call — cheap enough at once per frame, and it must
    # not freeze a value at first paint, since an override can land at any time.
    def color_count : Int32
      self.class.resolve_color_depth(tput.features.number_of_colors)
    end

    # :ditto: (alias; call sites are wide, so kept for compatibility).
    def colors : Int32
      color_count
    end

    # Resolves the effective output color count from the `colors.depth` config
    # option and the `screen.color_force` policy (resolved once at startup from
    # the `NO_COLOR` / `FORCE_COLOR` / `CLICOLOR[_FORCE]` conventions), falling
    # back to the terminal-detected count. `1` means monochrome (no color
    # emitted; styles still apply).
    def self.resolve_color_depth(detected : Int32) : Int32
      # An explicit config depth wins outright.
      if forced = Config.colors_depth.to_count
        return forced
      end
      case Config.screen_color_force
      in ColorForce::None      then detected
      in ColorForce::Mono      then 1
      in ColorForce::Min16     then {detected, 16}.max
      in ColorForce::Min256    then {detected, 256}.max
      in ColorForce::Truecolor then 0x1000000
      end
    end

    # Whether the output terminal can render the full 24-bit (TrueColor) space,
    # i.e. colors are emitted as `38;2;r;g;b` rather than reduced to a palette.
    def truecolor?
      color_count >= 0x1000000
    end
  end
end
