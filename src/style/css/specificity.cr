module Crysterm
  module CSS
    # Computes CSS selector specificity as an `{a, b, c}` triple — ids,
    # then classes/attributes/pseudo-classes, then types/pseudo-elements —
    # compared lexicographically (`Tuple` is `Comparable`).
    #
    # This is a real single-pass tokenizer rather than a character count, so it
    # is correct in the cases the count got wrong: it skips the contents of
    # `[...]` attribute values and `(...)` pseudo arguments (so a `.` or `#`
    # inside a quoted attribute value isn't miscounted), distinguishes `::`
    # pseudo-elements from `:` pseudo-classes, ignores `*` and combinators, and
    # recurses into `:not()`/`:is()` (and treats `:where()` as zero, per spec).
    module Specificity
      # Functional pseudo-classes whose argument's specificity replaces the
      # pseudo-class itself.
      RECURSIVE_PSEUDOS = {"not", "is", "matches", "has"}

      # ameba:disable Metrics/CyclomaticComplexity
      def self.calculate(selector : String) : Tuple(Int32, Int32, Int32)
        a = b = c = 0
        chars = selector.chars
        i = 0
        n = chars.size

        while i < n
          case ch = chars[i]
          when '#'
            a += 1
            i = skip_ident(chars, i + 1)
          when '.'
            b += 1
            i = skip_ident(chars, i + 1)
          when '['
            b += 1
            i = skip_balanced(chars, i, '[', ']')
          when ':'
            if i + 1 < n && chars[i + 1] == ':'
              c += 1 # pseudo-element
              i = skip_ident(chars, i + 2)
            else
              name_end = skip_ident(chars, i + 1)
              name = String.build { |str| (i + 1...name_end).each { |idx| str << chars[idx] } }
              if name_end < n && chars[name_end] == '('
                arg_end = skip_balanced(chars, name_end, '(', ')')
                if RECURSIVE_PSEUDOS.includes?(name)
                  arg = String.build { |str| (name_end + 1...arg_end - 1).each { |idx| str << chars[idx] } }
                  aa, bb, cc = calculate(arg)
                  a += aa; b += bb; c += cc
                elsif name != "where"
                  b += 1
                end
                # `:where(...)` contributes nothing.
                i = arg_end
              else
                b += 1
                i = name_end
              end
            end
          when '*', '>', '+', '~', ',', ' ', '\t', '\n', '\r'
            i += 1
          else
            if ident_start?(ch)
              c += 1 # type selector
              i = skip_ident(chars, i + 1)
            else
              i += 1
            end
          end
        end

        {a, b, c}
      end

      # Advances past an identifier run (letters, digits, `-`, `_`).
      private def self.skip_ident(chars : Array(Char), i : Int32) : Int32
        while i < chars.size && ident?(chars[i])
          i += 1
        end
        i
      end

      # Advances past a region opened by *open* at index *i* to just after its
      # matching *close*, honoring nesting and quoted strings.
      private def self.skip_balanced(chars : Array(Char), i : Int32, open : Char, close : Char) : Int32
        depth = 0
        n = chars.size
        while i < n
          ch = chars[i]
          if ch == '"' || ch == '\''
            i = skip_string(chars, i)
            next
          elsif ch == open
            depth += 1
          elsif ch == close
            depth -= 1
            return i + 1 if depth == 0
          end
          i += 1
        end
        i
      end

      # Advances past a quoted string starting at the opening quote *i*.
      private def self.skip_string(chars : Array(Char), i : Int32) : Int32
        quote = chars[i]
        i += 1
        n = chars.size
        while i < n
          return i + 1 if chars[i] == quote
          i += 2 if chars[i] == '\\' # skip escaped char
          i += 1
        end
        i
      end

      private def self.ident?(ch : Char) : Bool
        ch.alphanumeric? || ch == '-' || ch == '_'
      end

      private def self.ident_start?(ch : Char) : Bool
        ch.letter? || ch == '-' || ch == '_'
      end
    end
  end
end
