require "./box"

module Crysterm
  class Widget
    # Seven-segment numeric display, modeled after Qt's `QLCDNumber`.
    #
    # Renders a number (or a short string of digits/`A`–`F`/`-`/`.`/`:`) in a
    # three-row seven-segment font built from `_` and `|`. `#display` shows an
    # `Int` (formatted per `#mode`), a `Float`, or a `String`, right-aligned in
    # `#digit_count` cells. Needs three rows of interior height (e.g. `height: 3`,
    # or `5` with a border).
    #
    # ```
    # lcd = Widget::LCDNumber.new parent: window, width: 24, height: 3, digit_count: 5, style: Style.new(fg: "red")
    # lcd.display 1234
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![LCDNumber screenshot](../../tests/widget/lcd_number/lcd_number.5s.apng)
    # <!-- /widget-examples:capture -->
    class LCDNumber < Box
      enum Mode
        Dec
        Hex
        Oct
        Bin
      end

      # Three-row glyphs (top/middle/bottom), each 3 cells wide.
      SEGMENTS = {
        '0' => {" _ ", "| |", "|_|"},
        '1' => {"   ", "  |", "  |"},
        '2' => {" _ ", " _|", "|_ "},
        '3' => {" _ ", " _|", " _|"},
        '4' => {"   ", "|_|", "  |"},
        '5' => {" _ ", "|_ ", " _|"},
        '6' => {" _ ", "|_ ", "|_|"},
        '7' => {" _ ", "  |", "  |"},
        '8' => {" _ ", "|_|", "|_|"},
        '9' => {" _ ", "|_|", " _|"},
        'A' => {" _ ", "|_|", "| |"},
        'B' => {"   ", "|_ ", "|_|"},
        'C' => {" _ ", "|  ", "|_ "},
        'D' => {"   ", " _|", "|_|"},
        'E' => {" _ ", "|_ ", "|_ "},
        'F' => {" _ ", "|_ ", "|  "},
        '-' => {"   ", " _ ", "   "},
        ' ' => {"   ", "   ", "   "},
        '.' => {"   ", "   ", " . "},
        ':' => {"   ", " . ", " . "},
      }

      EMPTY = {"   ", "   ", "   "}

      # Number of character cells the value is right-aligned within.
      getter digit_count : Int32 = 5

      # Base used to format an `Int` passed to `#display`.
      getter mode : Mode = :dec

      # The string currently shown (digits/letters/punctuation).
      getter text : String = ""

      # The last integer passed to `#display`, retained so a later `#mode=` can
      # re-format it in the new base — the shown `@text` is already
      # base-formatted. `nil` after a Float/String display, where no base applies.
      @last_int : Int64?

      # The numeric value on display (Qt's `QLCDNumber#value`). Kept alongside
      # `#text` because the shown string is base-formatted and padded, so it
      # can't be parsed back reliably. A `#display(String)` resets it to `0.0`,
      # as in Qt — an arbitrary string has no value.
      getter value : Float64 = 0.0

      # The value rounded to an integer (Qt's `QLCDNumber#intValue`).
      def int_value : Int64
        @value.round.to_i64
      end

      # Shows *v* (Qt has no `setValue`; this is `#display`'s setter spelling,
      # so `lcd.value = 42` reads like every other numeric widget).
      def value=(v : Int | Float) : Nil
        display v
      end

      # Re-aligns the shown value in the new cell count immediately; a plain
      # property setter would be inert until the next `#display`.
      def digit_count=(v : Int32) : Int32
        return v if v == @digit_count
        @digit_count = v
        update_content
        request_render
        v
      end

      # Re-formats the retained integer in the new base immediately; a plain
      # property setter would leave `display 255` then `mode = :hex` showing 255.
      # A Float/String display has no base to re-apply.
      def mode=(m : Mode) : Mode
        return m if m == @mode
        @mode = m
        if v = @last_int
          display v
        end
        m
      end

      def initialize(value : Int | Float | String? = nil, digit_count = 5, mode : Mode = :dec, **box)
        @digit_count = digit_count
        @mode = mode

        super **box

        case value
        in Int    then display value
        in Float  then display value
        in String then display value
        in Nil    then update_content
        end
      end

      # Shows *value* formatted per `#mode`.
      def display(value : Int) : Nil
        @last_int = value.to_i64
        @value = value.to_f
        s = case @mode
            when .hex? then value.to_s(16).upcase
            when .oct? then value.to_s(8)
            when .bin? then value.to_s(2)
            else            value.to_s
            end
        show_text s
      end

      # Shows *value* (its default string form).
      def display(value : Float) : Nil
        @last_int = nil
        @value = value.to_f
        show_text value.to_s
      end

      # Shows the literal *value* (unknown characters render blank).
      def display(value : String) : Nil
        @last_int = nil
        @value = 0.0
        show_text value
      end

      private def show_text(s : String) : Nil
        @text = s
        update_content
        request_render
      end

      private def update_content : Nil
        shown = @text.size < @digit_count ? @text.rjust(@digit_count) : @text
        set_content render_segments(shown)
      end

      # Builds the three-row seven-segment rendering of *str*.
      private def render_segments(str : String) : String
        last = str.size - 1
        String.build do |io|
          3.times do |r|
            io << '\n' if r > 0
            str.each_char_with_index do |ch, i|
              seg = SEGMENTS[ch.upcase]? || EMPTY
              io << seg[r]
              io << ' ' if i < last # one-cell gap between glyphs
            end
          end
        end
      end
    end
  end
end
