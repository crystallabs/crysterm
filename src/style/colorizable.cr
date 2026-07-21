module Crysterm
  # Color setter overloads shared by `Style` and `Border`.
  #
  # Colors are stored as native `0xRRGGBB` ints (`-1` = terminal default,
  # `nil` = unset); `"#rrggbb"`/named-color strings are also accepted and parsed
  # via `Colors.convert`. Including class must declare `@fg`/`@bg` as `Int32?`.
  module Colorizable
    @fg : Int32?
    @bg : Int32?

    # Generates three setter overloads for a `@name` ivar: native `Int` stored
    # directly, `"#rrggbb"`/named-color `String` parsed via
    # `Colors.convert_cached`, and `Nil` which clears it (no SGR emitted). The
    # getter is declared by each including class.
    macro color_setter(name)
      def {{ name.id }}=(color : Int)
        @{{ name.id }} = color.to_i32
      end

      def {{ name.id }}=(color : String)
        @{{ name.id }} = Colors.convert_cached(color)
      end

      def {{ name.id }}=(color : Nil)
        @{{ name.id }} = nil
      end
    end

    color_setter fg
    color_setter bg
  end
end
