module Crysterm
  module CSS
    # Selector text utilities, plus the shared allocation-free `String`+index
    # scanning primitives (`skip_balanced`, `skip_string`) the CSS parsers use.
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
