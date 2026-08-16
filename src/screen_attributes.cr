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
    # Memoized behind config invalidation: the answer is recomputed only when
    # one of its three inputs (the `colors.depth` option, the
    # `screen.color_force` policy, the terminal-detected count) changes, so an
    # override landing at runtime still reaches the wire while the hot paths
    # (`Direct`'s per-SGR-write reduction, the per-frame draw loop) pay a
    # three-field compare instead of the full resolve.
    def color_count : Int32
      detected = tput.features.number_of_colors
      key = {Config.colors_depth, Config.screen_color_force, detected}
      if @color_count_key != key
        @color_count_key = key
        @color_count = self.class.resolve_color_depth(detected)
      end
      @color_count
    end

    # Memo for `#color_count` and the input triple it was computed against.
    @color_count : Int32 = 0
    @color_count_key : Tuple(ColorDepth, ColorForce, Int32)? = nil

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
