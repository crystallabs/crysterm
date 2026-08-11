module Crysterm
  # Qt-style `&` mnemonics in widget labels (`"&File"`): the marked letter is
  # the label's keyboard accelerator and is drawn underlined; `"&&"` produces a
  # literal ampersand. Mirrors Qt's rules — the FIRST `&<char>` marks the
  # mnemonic, every `&&` collapses to one `&`, and a trailing lone `&` stays
  # literal.
  module Mnemonic
    # Parses *label* into `{clean, char, index}`: the label with markers
    # resolved, the mnemonic character (downcased; `nil` when none), and the
    # mnemonic's character index within *clean* (`nil` when none).
    def self.parse(label : String) : {String, Char?, Int32?}
      return {label, nil, nil} unless label.includes? '&'
      mnemonic = nil
      index = nil
      count = 0
      pending = false
      clean = String.build do |b|
        label.each_char do |c|
          if pending
            pending = false
            if c != '&' && mnemonic.nil?
              mnemonic = c.downcase
              index = count
            end
            b << c
            count += 1
          elsif c == '&'
            pending = true
          else
            b << c
            count += 1
          end
        end
        b << '&' if pending
      end
      {clean, mnemonic, index}
    end

    # Like `.parse`, but returns the clean label with its mnemonic letter
    # wrapped in `{underline}…{/underline}` for rendering by a
    # `parse_tags`-enabled widget (`"&File"` → `"{underline}F{/underline}ile"`),
    # plus the mnemonic character. Labels without a mnemonic pass through
    # untouched (and unescaped); a tagged label gets its literal braces
    # `{`/`}` escaped to `{open}`/`{close}`, so they still render as
    # themselves once the label is tag-parsed.
    def self.tagged(label : String) : {String, Char?}
      clean, mnemonic, index = parse label
      return {clean, nil} unless index
      tagged = String.build do |b|
        clean.each_char_with_index do |c, i|
          b << "{underline}" if i == index
          case c
          when '{' then b << "{open}"
          when '}' then b << "{close}"
          else          b << c
          end
          b << "{/underline}" if i == index
        end
      end
      {tagged, mnemonic}
    end
  end
end
