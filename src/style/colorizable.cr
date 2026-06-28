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

    # Generates the three color-setter overloads for a `@name` ivar: a native
    # `Int` (`fg: 0x40e0c0`) stored directly, a `"#rrggbb"`/named-color `String`
    # parsed via `Colors.convert_cached` (backwards compatibility), and `Nil`
    # which clears it (unset → no SGR sequence emitted). Shared verbatim by
    # `fg`/`bg` here and by `Style`'s `tint`/`gridline_color` (which mix it in
    # via `Colorizable.color_setter`); the getter is declared by each class.
    macro color_setter(name)
      def {{name.id}}=(color : Int)
        @{{name.id}} = color.to_i32
      end

      def {{name.id}}=(color : String)
        @{{name.id}} = Colors.convert_cached(color)
      end

      def {{name.id}}=(color : Nil)
        @{{name.id}} = nil
      end
    end

    # `fg`/`bg` color setters (Int/String/Nil); see `color_setter`.
    color_setter fg
    color_setter bg
  end
end
