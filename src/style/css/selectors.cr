module Crysterm
  module CSS
    # Selector text utilities, plus the shared allocation-free `String`+index
    # scanning primitives (`skip_balanced`, `skip_string`, `matching_paren`,
    # `top_level_comma`, `split_top_level`, `split_subject`,
    # `compound_end_index`) the CSS parsers use.
    module Selectors
      # Rewrites bare *type* selectors into *class* selectors so widget type
      # names emitted as element classes can be targeted by their plain name.
      #
      # `Box` -> `.Box`, `Form > Button` -> `.Form > .Button`,
      # `Button:focus` -> `.Button:focus`. Selectors already prefixed with
      # `.`/`#`, attribute selectors (`[...]`), pseudo-classes (`:...`) and the
      # universal `*` are left as-is. Parenthesized pseudo arguments (e.g.
      # `:not(...)`, `:nth-child(...)`) are copied verbatim — so inside `:not()`
      # use the class form (`.Box`) explicitly.
      def self.expand_types(selector : String) : String
        n = selector.size
        String.build do |io|
          i = 0
          while i < n
            case ch = selector[i]
            when '.', '#'
              io << ch
              i = copy_ident(selector, i + 1, io)
            when ':'
              io << ch
              i += 1
              if i < n && selector[i] == ':'
                io << ':'
                i += 1
              end
              i = copy_ident(selector, i, io) # pseudo name, kept verbatim
            when '['
              i = copy_balanced(selector, i, '[', ']', io)
            when '('
              i = copy_balanced(selector, i, '(', ')', io)
            else
              if ident_start?(ch)
                io << '.' # bare type selector -> class selector
                i = copy_ident(selector, i, io)
              else
                io << ch
                i += 1
              end
            end
          end
        end
      end

      # The *selector* as handed to the `html5` engine: every presence-only
      # attribute selector (`[checked]`, no `=`) is followed by an empty
      # comment, `[checked]/**/`.
      #
      # The engine's compiler consumes the closing `]` of a presence-only
      # attribute itself and then, like after every other simple selector,
      # steps past one more token — the one that follows the `]`. Where that is
      # the end of the selector nothing is lost, but anywhere else it is a
      # combinator or a closing paren, and dropping it changes the selector:
      # `CheckBox[checked] ~ Label` compiles as `CheckBox[checked] Label` (the
      # tilde is eaten along with the space before it, the space after it
      # becomes a descendant combinator), `Box[x] Label` as `Box[x].Label`, and
      # `:not([checked])` does not compile. The comment is a token the engine
      # skips without meaning, so the extra step lands on it and the token
      # after the `]` survives. A valued `[attr="v"]` is left alone: there the
      # compiler leaves the `]` for that extra step.
      #
      # Applied where a selector is compiled, never to the stored rule text, so
      # `Rule#selector` (which the patch path's token test reads) is unchanged.
      def self.engine_form(selector : String) : String
        return selector unless selector.includes?('[')
        n = selector.size
        String.build do |io|
          i = 0
          while i < n
            case selector[i]
            when '"', '\''
              stop = skip_string(selector, i)
              io << selector[i...stop]
              i = stop
            when '['
              stop = skip_balanced(selector, i, '[', ']')
              io << selector[i...stop]
              io << "/**/" if presence_attribute?(selector, i, stop)
              i = stop
            else
              io << selector[i]
              i += 1
            end
          end
        end
      end

      # Whether the attribute selector spanning *start*...*stop* in *selector*
      # (`[` through `]`) tests presence only: it holds no `=` outside quotes.
      private def self.presence_attribute?(selector : String, start : Int32, stop : Int32) : Bool
        i = start + 1
        while i < stop
          ch = selector[i]
          if ch == '"' || ch == '\''
            i = skip_string(selector, i)
            next
          end
          return false if ch == '='
          i += 1
        end
        true
      end

      private def self.copy_ident(str : String, i : Int32, io) : Int32
        while i < str.size && ident?(str[i])
          io << str[i]
          i += 1
        end
        i
      end

      # Copies the balanced region opened by *open* at *i* verbatim into *io*,
      # returning the index just past its matching *close*.
      private def self.copy_balanced(str : String, i : Int32, open : Char, close : Char, io) : Int32
        stop = skip_balanced(str, i, open, close)
        io << str[i...stop]
        stop
      end

      # Index just past the region opened by *open* at *i* up to its matching
      # *close*, honoring nesting and quoted strings.
      def self.skip_balanced(str : String, i : Int32, open : Char, close : Char) : Int32
        depth = 0
        n = str.size
        while i < n
          ch = str[i]
          if ch == '"' || ch == '\''
            i = skip_string(str, i)
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

      # Index just past the quoted string starting at the opening quote *i*,
      # honoring backslash escapes.
      def self.skip_string(str : String, i : Int32) : Int32
        quote = str[i]
        i += 1
        n = str.size
        while i < n
          return i + 1 if str[i] == quote
          # Skip the escaped char; the `i + 1 < n` guard keeps a malformed
          # trailing `\` from running the index past the string end.
          i += 1 if str[i] == '\\' && i + 1 < n
          i += 1
        end
        i
      end

      # Index of the `)` matching the `(` at *open*, honoring nesting; `nil` if
      # unbalanced.
      def self.matching_paren(selector : String, open : Int32) : Int32?
        depth = 0
        i = open
        while i < selector.size
          case selector[i]
          when '"', '\''
            i = skip_string(selector, i) # a paren inside a quoted value doesn't nest
            next
          when '(' then depth += 1
          when ')'
            depth -= 1
            return i if depth == 0
          end
          i += 1
        end
        nil
      end

      # Index of the first top-level (paren-depth-0) comma in *value*, or `nil` —
      # the separator between a `var()`'s name and its fallback, skipping commas
      # inside a nested function's parens.
      def self.top_level_comma(value : String) : Int32?
        depth = 0
        i = 0
        while i < value.size
          case value[i]
          when '"', '\''
            i = skip_string(value, i) # a comma inside a quoted string isn't the separator
            next
          when '(' then depth += 1
          when ')' then depth -= 1
          when ',' then return i if depth == 0
          end
          i += 1
        end
        nil
      end

      # Splits a multi-token shorthand value on top-level whitespace, keeping a
      # function's parenthesized argument list intact so a color function with
      # internal spaces/commas (`rgb(30, 30, 46)`) survives as one token rather
      # than being shredded by a plain `String#split`.
      # With *separator* nil, splits on top-level whitespace (the token form);
      # given a separator char (e.g. `','` for `transition` entries), splits on
      # top-level occurrences of it instead, keeping other whitespace inside the
      # pieces. Quoted spans (`" "`/`' '`) are skipped whole via
      # `Selectors.skip_string`, so a quoted space glyph value (`border-chars:
      # " " "x" "y"`) stays one token instead of being shredded into bare
      # quote fragments.
      def self.split_top_level(value : String, separator : Char? = nil) : Array(String)
        tokens = [] of String
        depth = 0
        start = 0
        i = 0
        n = value.size
        while i < n
          case ch = value[i]
          when '('
            depth += 1
            i += 1
          when ')'
            depth -= 1 if depth > 0
            i += 1
          when '"', '\''
            i = skip_string(value, i)
          else
            if depth == 0 && (separator ? ch == separator : ch.whitespace?)
              tokens << value[start...i] unless i == start
              start = i + 1
            end
            i += 1
          end
        end
        tokens << value[start..] if start < n
        tokens
      end

      # Splits a selector into `{prefix, subject}`, where *subject* is the
      # rightmost compound (after the last top-level combinator) and *prefix* is
      # everything up to and including that combinator (so `prefix + subject`
      # reconstructs the selector). Combinators inside `[...]`/`(...)` are ignored.
      def self.split_subject(selector : String) : Tuple(String, String)
        depth = 0
        cut = -1
        i = 0
        while i < selector.size
          char = selector[i]
          if char == '"' || char == '\''
            i = skip_string(selector, i) # a combinator inside a quoted value is not structural
            next
          end
          case char
          when '[', '(' then depth += 1
          when ']', ')' then depth -= 1
          when ' ', '>', '+', '~'
            cut = i + 1 if depth == 0
          end
          i += 1
        end
        return {"", selector} if cut < 0
        {selector[0...cut], selector[cut..].strip}
      end

      # Index of the end of the compound that begins at/contains *from* — the
      # first top-level combinator (space/`>`/`+`/`~`) at or after *from*, or the
      # end of *selector*. Combinators inside `[...]`/`(...)` are ignored.
      def self.compound_end_index(selector : String, from : Int32) : Int32
        depth = 0
        i = from
        while i < selector.size
          case selector[i]
          when '"', '\''
            i = skip_string(selector, i) # a combinator inside a quoted value isn't structural
            next
          when '[', '(' then depth += 1
          when ']', ')' then depth -= 1
          when ' ', '>', '+', '~'
            return i if depth == 0
          end
          i += 1
        end
        selector.size
      end

      # Whether *ch* may appear inside a CSS identifier.
      def self.ident?(ch : Char) : Bool
        ch.alphanumeric? || ch == '-' || ch == '_'
      end

      # Whether *ch* may *start* a CSS identifier (a bare type selector).
      def self.ident_start?(ch : Char) : Bool
        ch.letter? || ch == '-' || ch == '_'
      end
    end
  end
end
