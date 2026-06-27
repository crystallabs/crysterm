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
            i = Selectors.skip_balanced(chars, i, '[', ']')
          when ':'
            if i + 1 < n && chars[i + 1] == ':'
              c += 1 # pseudo-element
              i = skip_ident(chars, i + 2)
            else
              name_end = skip_ident(chars, i + 1)
              name = String.build { |str| (i + 1...name_end).each { |idx| str << chars[idx] } }
              if name_end < n && chars[name_end] == '('
                arg_end = Selectors.skip_balanced(chars, name_end, '(', ')')
                if RECURSIVE_PSEUDOS.includes?(name)
                  arg = String.build { |str| (name_end + 1...arg_end - 1).each { |idx| str << chars[idx] } }
                  aa, bb, cc = max_specificity(arg)
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
            if Selectors.ident_start?(ch)
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
        while i < chars.size && Selectors.ident?(chars[i])
          i += 1
        end
        i
      end

      # The specificity a functional pseudo-class (`:is()`/`:not()`/`:has()`)
      # contributes for *arg*, its argument: per Selectors Level 4 this is the
      # specificity of its *most specific* argument — the maximum over the
      # comma-separated list, NOT the sum. Each argument's full `(a, b, c)` is
      # computed and the tuples compared lexicographically (`Tuple` is
      # `Comparable`), so the single argument with the highest overall
      # specificity wins. An empty argument list contributes nothing.
      private def self.max_specificity(arg : String) : Tuple(Int32, Int32, Int32)
        best = {0, 0, 0}
        each_top_level_arg(arg) do |part|
          s = calculate(part)
          best = s if s > best
        end
        best
      end

      # Yields each top-level (comma-separated) argument of a functional
      # pseudo-class, skipping commas nested inside `[...]`/`(...)` or quoted
      # strings so a selector list like `:is(.a, [x=","] b)` splits correctly.
      private def self.each_top_level_arg(arg : String, & : String ->) : Nil
        chars = arg.chars
        n = chars.size
        i = 0
        start = 0
        while i < n
          case chars[i]
          when '['       then i = Selectors.skip_balanced(chars, i, '[', ']')
          when '('       then i = Selectors.skip_balanced(chars, i, '(', ')')
          when '"', '\'' then i = Selectors.skip_string(chars, i)
          when ','
            yield arg[start...i]
            i += 1
            start = i
          else
            i += 1
          end
        end
        yield arg[start..]
      end

    end
  end
end
