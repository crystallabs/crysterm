module Crysterm
  module Neovim
    # Translation of Crysterm key events into Neovim's key notation
    # (`:help key-notation`), what `nvim_input` takes: `"a"`, `"<lt>"` for
    # `<`, `"<CR>"`, `"<Esc>"`, `"<C-a>"`, `"<M-x>"`, `"<S-Tab>"`, `"<Up>"`,
    # `"<C-Left>"`, `"<F5>"`, …
    #
    # Works from either shape a key press comes in: the legacy one (a `char`
    # and a flat `Tput::Key`) and, when the terminal speaks an enhanced
    # keyboard protocol, the `Tput::KeyEvent`, which carries the full set of
    # modifiers (so `<C-S-a>` or `<M-CR>` come through).
    #
    # ```
    # Crysterm::Neovim::Keys.notation('<', nil)                  # => "<lt>"
    # Crysterm::Neovim::Keys.notation('\0', Tput::Key::CtrlLeft) # => "<C-Left>"
    # widget.on(Crysterm::Event::KeyPress) do |e|
    #   if keys = Crysterm::Neovim::Keys.notation(e)
    #     nvim.notify "nvim_input", keys
    #     e.accept
    #   end
    # end
    # ```
    module Keys
      extend self

      # Legacy keys with a name of their own in Neovim's notation. The
      # members `Tput::Key` aliases (`Tab`/`CtrlI`, `Enter`/`CtrlM`) map by
      # value, so the name listed here wins over `<C-i>`/`<C-m>`.
      NAMED = {
        ::Tput::Key::Enter     => "<CR>",
        ::Tput::Key::Tab       => "<Tab>",
        ::Tput::Key::Escape    => "<Esc>",
        ::Tput::Key::Space     => "<Space>",
        ::Tput::Key::Backspace => "<BS>",
        ::Tput::Key::AltEnter  => "<M-CR>",
        ::Tput::Key::ShiftTab  => "<S-Tab>",
        ::Tput::Key::Home      => "<Home>",
        ::Tput::Key::End       => "<End>",
        ::Tput::Key::PageUp    => "<PageUp>",
        ::Tput::Key::PageDown  => "<PageDown>",
        ::Tput::Key::Insert    => "<Insert>",
        ::Tput::Key::Delete    => "<Del>",
        ::Tput::Key::Clear     => "<kOrigin>",
        ::Tput::Key::Up        => "<Up>",
        ::Tput::Key::Down      => "<Down>",
        ::Tput::Key::Left      => "<Left>",
        ::Tput::Key::Right     => "<Right>",

        ::Tput::Key::ShiftUp       => "<S-Up>",
        ::Tput::Key::ShiftDown     => "<S-Down>",
        ::Tput::Key::ShiftLeft     => "<S-Left>",
        ::Tput::Key::ShiftRight    => "<S-Right>",
        ::Tput::Key::CtrlUp        => "<C-Up>",
        ::Tput::Key::CtrlDown      => "<C-Down>",
        ::Tput::Key::CtrlLeft      => "<C-Left>",
        ::Tput::Key::CtrlRight     => "<C-Right>",
        ::Tput::Key::AltUp         => "<M-Up>",
        ::Tput::Key::AltDown       => "<M-Down>",
        ::Tput::Key::AltLeft       => "<M-Left>",
        ::Tput::Key::AltRight      => "<M-Right>",
        ::Tput::Key::ShiftHome     => "<S-Home>",
        ::Tput::Key::ShiftEnd      => "<S-End>",
        ::Tput::Key::ShiftInsert   => "<S-Insert>",
        ::Tput::Key::ShiftDelete   => "<S-Del>",
        ::Tput::Key::ShiftPageUp   => "<S-PageUp>",
        ::Tput::Key::ShiftPageDown => "<S-PageDown>",
        ::Tput::Key::CtrlHome      => "<C-Home>",
        ::Tput::Key::CtrlEnd       => "<C-End>",
        ::Tput::Key::CtrlInsert    => "<C-Insert>",
        ::Tput::Key::CtrlDelete    => "<C-Del>",
        ::Tput::Key::CtrlPageUp    => "<C-PageUp>",
        ::Tput::Key::CtrlPageDown  => "<C-PageDown>",
        ::Tput::Key::AltHome       => "<M-Home>",
        ::Tput::Key::AltEnd        => "<M-End>",
        ::Tput::Key::AltInsert     => "<M-Insert>",
        ::Tput::Key::AltDelete     => "<M-Del>",
        ::Tput::Key::AltPageUp     => "<M-PageUp>",
        ::Tput::Key::AltPageDown   => "<M-PageDown>",
      }

      # The notation of a key press, or `nil` for one Neovim has no input
      # for (a release, a lone modifier, a mouse or paste marker). Reads the
      # `Tput::KeyEvent` when the terminal sent one, the legacy `char`/`key`
      # otherwise.
      def notation(e : ::Crysterm::Event::KeyPress) : String?
        if ke = e.key_event
          notation ke
        else
          notation e.char, e.key
        end
      end

      # The notation of a legacy key press: *key* when there is one (`Tput::
      # Key::CtrlA` → `"<C-a>"`, `AltX` → `"<M-x>"`, `F5` → `"<F5>"`), else
      # the character *char* (`'a'` → `"a"`, `'<'` → `"<lt>"`, a control
      # character → its `<C-…>`).
      def notation(char : Char, key : ::Tput::Key?) : String?
        if key
          if name = NAMED[key]?
            return name
          end
          v = key.value
          return "<C-#{(v + 'a'.ord - 1).chr}>" if 1 <= v <= 26
          if ::Tput::Key::AltA.value <= v <= ::Tput::Key::AltZ.value
            return "<M-#{(v - ::Tput::Key::AltA.value + 'a'.ord).chr}>"
          end
          if ::Tput::Key::F1.value <= v <= ::Tput::Key::F24.value
            return "<F#{v - ::Tput::Key::F1.value + 1}>"
          end
          # Keys that are no keystroke (`Mouse`, `PasteStart`, `Resize`, …)
          # and those unknown: the character, when it is one, else nothing.
          return if v >= ::Tput::Key::Menu.value
        end
        char_notation char
      end

      # The notation of an enhanced-protocol key press, with every modifier
      # it reports (`<C-S-a>`, `<M-CR>`, `<D-s>` for Super). `nil` for a
      # release and a lone modifier.
      def notation(ke : ::Tput::KeyEvent) : String?
        return unless ke.press? || ke.repeat?
        return if ke.modifier_key?
        shift = ke.shift?
        name =
          case ke.final
          when 'A' then "Up"
          when 'B' then "Down"
          when 'C' then "Right"
          when 'D' then "Left"
          when 'H' then "Home"
          when 'F' then "End"
          when 'P' then "F1"
          when 'Q' then "F2"
          when 'R' then "F3"
          when 'S' then "F4"
          when '~' then tilde_name ke.number
          when 'u'
            case n = ke.number
            when  27 then "Esc"
            when  13 then "CR"
            when   9 then "Tab"
            when 127 then "BS"
            when  32 then "Space"
            else
              return if n < 0x20 || (0xE000 <= n <= 0xF8FF)
              modded = ke.ctrl? || ke.alt? || ke.meta? || ke.super?
              base = n.chr rescue return
              if modded
                # With Ctrl/Alt/Super the key itself is named, and Shift
                # stays a modifier: `<C-S-a>`.
                base.to_s
              else
                # A text key: the character it types — the terminal's text
                # when it sent that, else the shifted character it reported
                # (or a letter's capital) — Shift being in the character.
                shift = false
                ch =
                  if (t = ke.text) && (c = t[0]?)
                    c
                  elsif ke.shift? && (s = ke.shifted)
                    s.chr rescue base
                  elsif ke.shift?
                    base.upcase
                  else
                    base
                  end
                ch.to_s
              end
            end
          end
        return unless name

        mods = String.build do |io|
          io << "S-" if shift
          io << "C-" if ke.ctrl?
          io << "M-" if ke.alt? || ke.meta?
          io << "D-" if ke.super?
        end
        if mods.empty?
          name.size == 1 ? char_notation(name[0]) : "<#{name}>"
        else
          "<#{mods}#{special_char_name(name)}>"
        end
      end

      # The name of a key reported with a `~` final, by its number.
      private def tilde_name(n : Int32) : String?
        case n
        when 1, 7 then "Home"
        when 2    then "Insert"
        when 3    then "Del"
        when 4, 8 then "End"
        when 5    then "PageUp"
        when 6    then "PageDown"
        when 11   then "F1"
        when 12   then "F2"
        when 13   then "F3"
        when 14   then "F4"
        when 15   then "F5"
        when 17   then "F6"
        when 18   then "F7"
        when 19   then "F8"
        when 20   then "F9"
        when 21   then "F10"
        when 23   then "F11"
        when 24   then "F12"
        end
      end

      # A character inside `<…>` with a modifier: `<` and `>` are spelt
      # `lt`/`gt`, a backslash `Bslash` and a bar `Bar`.
      private def special_char_name(name : String) : String
        case name
        when "<"  then "lt"
        when ">"  then "gt"
        when "\\" then "Bslash"
        when "|"  then "Bar"
        else           name
        end
      end

      # The notation of a typed character: itself, except `<` (`"<lt>"`,
      # since `nvim_input` reads `<` as the start of a key name) and the
      # control characters (`"<C-a>"`, `"<Esc>"`, `"<CR>"`, …). `nil` for
      # NUL, which is no keystroke.
      def char_notation(char : Char) : String?
        case char
        when '<'            then "<lt>"
        when '\e'           then "<Esc>"
        when '\r'           then "<CR>"
        when '\n'           then "<C-j>"
        when '\t'           then "<Tab>"
        when '\u007f', '\b' then "<BS>"
        when '\0'           then nil
        else
          o = char.ord
          if o < 0x20
            "<C-#{(o + 'a'.ord - 1).chr}>"
          else
            char.to_s
          end
        end
      end
    end
  end
end
