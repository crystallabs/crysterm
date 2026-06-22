module Crysterm
  # Mixin providing the color setter overloads shared by `Style` and `Border`.
  #
  # Both classes store colors as native `0xRRGGBB` ints (`-1` = terminal
  # default, `nil` = unset) but, for backwards compatibility, also accept
  # `"#rrggbb"`/named-color strings, which are parsed via `Colors.convert`.
  # The including class is expected to declare `@fg`/`@bg` (as `Int32?`).
  module Colorizable
    @fg : Int32?
    @bg : Int32?

    # Native numeric color (e.g. `fg: 0x40e0c0`); stored directly.
    def fg=(color : Int)
      @fg = color.to_i32
    end

    # :ditto:
    def bg=(color : Int)
      @bg = color.to_i32
    end

    # Backwards compatibility: a `"#rrggbb"` or named ("blue") color string is
    # parsed to the native int.
    def fg=(color : String)
      @fg = Colors.convert(color).to_i32
    end

    # :ditto:
    def bg=(color : String)
      @bg = Colors.convert(color).to_i32
    end

    # Clearing a color leaves it unset (no SGR sequence emitted).
    def fg=(color : Nil)
      @fg = nil
    end

    # :ditto:
    def bg=(color : Nil)
      @bg = nil
    end
  end
end
