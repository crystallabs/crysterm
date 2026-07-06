module Crysterm
  module CSS
    # Computes CSS selector specificity as an `{a, b, c}` triple — ids,
    # then classes/attributes/pseudo-classes, then types/pseudo-elements —
    # compared lexicographically (`Tuple` is `Comparable`).
    #
    # This is a real single-pass tokenizer rather than a naive character count,
    # so it handles the tricky cases correctly: it skips the contents of
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
        i = 0
        n = selector.size

        while i < n
          case ch = selector[i]
          when '#'
            a += 1
            i = skip_ident(selector, i + 1)
          when '.'
            b += 1
            i = skip_ident(selector, i + 1)
          when '['
            b += 1
            i = Selectors.skip_balanced(selector, i, '[', ']')
          when ':'
            if i + 1 < n && selector[i + 1] == ':'
              c += 1 # pseudo-element
              name_end = skip_ident(selector, i + 2)
              # A functional pseudo-element (`::foo(bar)`) — skip its argument so
              # `bar` isn't re-scanned as further selector tokens (double-count).
              i = (name_end < n && selector[name_end] == '(') ? Selectors.skip_balanced(selector, name_end, '(', ')') : name_end
            else
              name_end = skip_ident(selector, i + 1)
              # Pseudo-class names are case-insensitive; fold so `:NOT(#id)` scores
              # like `:not(#id)` (recurse into its argument) rather than counting
              # as a plain class, and `:WHERE(...)` contributes nothing like
              # `:where(...)`. (An ident here is never a custom-property/type name,
              # so folding is safe.)
              name = selector[(i + 1)...name_end].downcase
              if name_end < n && selector[name_end] == '('
                arg_end = Selectors.skip_balanced(selector, name_end, '(', ')')
                if RECURSIVE_PSEUDOS.includes?(name)
                  arg = selector[(name_end + 1)...(arg_end - 1)]
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
              i = skip_ident(selector, i + 1)
            else
              i += 1
            end
          end
        end

        {a, b, c}
      end

      # Advances past an identifier run (letters, digits, `-`, `_`).
      private def self.skip_ident(str : String, i : Int32) : Int32
        while i < str.size && Selectors.ident?(str[i])
          i += 1
        end
        i
      end

      # Specificity contributed by a functional pseudo-class's argument list
      # (`:is()`/`:not()`/`:has()`): per Selectors Level 4 this is the *max*
      # over the comma-separated arguments, not the sum. Empty list contributes nothing.
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
        n = arg.size
        i = 0
        start = 0
        while i < n
          case arg[i]
          when '['       then i = Selectors.skip_balanced(arg, i, '[', ']')
          when '('       then i = Selectors.skip_balanced(arg, i, '(', ')')
          when '"', '\'' then i = Selectors.skip_string(arg, i)
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
