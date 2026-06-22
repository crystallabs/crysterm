module Crysterm
  module CSS
    # Selector text utilities.
    module Selectors
      # Rewrites bare *type* selectors into *class* selectors so the widget type
      # names emitted as element classes can be targeted by their plain name.
      #
      # `Box` -> `.Box`, `Form > Button` -> `.Form > .Button`,
      # `Button:focus` -> `.Button:focus`. Selectors already prefixed with
      # `.`/`#`, attribute selectors (`[...]`), pseudo-classes (`:...`) and the
      # universal `*` are left as-is. Parenthesized pseudo arguments (e.g.
      # `:not(...)`, `:nth-child(...)`) are copied verbatim — so inside `:not()`
      # use the class form (`.Box`) explicitly.
      #
      # This is what makes `Box`/`ScrollBar`-style selectors work against the
      # class-based document while preserving exact PascalCase names.
      def self.expand_types(selector : String) : String
        chars = selector.chars
        n = chars.size
        String.build do |io|
          i = 0
          while i < n
            case ch = chars[i]
            when '.', '#'
              io << ch
              i = copy_ident(chars, i + 1, io)
            when ':'
              io << ch
              i += 1
              if i < n && chars[i] == ':'
                io << ':'
                i += 1
              end
              i = copy_ident(chars, i, io) # pseudo name, kept verbatim
            when '['
              i = copy_balanced(chars, i, '[', ']', io)
            when '('
              i = copy_balanced(chars, i, '(', ')', io)
            else
              if ident_start?(ch)
                io << '.' # bare type selector -> class selector
                i = copy_ident(chars, i, io)
              else
                io << ch
                i += 1
              end
            end
          end
        end
      end

      private def self.copy_ident(chars : Array(Char), i : Int32, io) : Int32
        while i < chars.size && ident?(chars[i])
          io << chars[i]
          i += 1
        end
        i
      end

      private def self.copy_balanced(chars : Array(Char), i : Int32, open : Char, close : Char, io) : Int32
        depth = 0
        n = chars.size
        while i < n
          ch = chars[i]
          if ch == '"' || ch == '\''
            i = copy_string(chars, i, io)
            next
          end
          io << ch
          if ch == open
            depth += 1
          elsif ch == close
            depth -= 1
            return i + 1 if depth == 0
          end
          i += 1
        end
        i
      end

      private def self.copy_string(chars : Array(Char), i : Int32, io) : Int32
        quote = chars[i]
        io << quote # the opening quote (copy_balanced delegates the whole string here)
        i += 1
        n = chars.size
        while i < n
          ch = chars[i]
          io << ch
          return i + 1 if ch == quote
          if ch == '\\' && i + 1 < n
            io << chars[i + 1]
            i += 1
          end
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
