module Crysterm
  # Suite-neutral text/number formatting helpers, shared by widgets that render
  # the same field the same way regardless of which suite they belong to.
  #
  # Homed here rather than under any one suite, so e.g. Pine's `MessageIndex`
  # never reaches into the Mutt namespace for `truncate` — that would be a
  # backwards cross-suite dependency.
  module Formatting
    # Formats a byte count the way Mutt's `%c` does: bytes, then `K`/`M` with
    # one decimal (e.g. `842`, `1.2K`, `3.4M`). Shared by `Widget::Mutt::MessageIndex`
    # and `Widget::Mutt::Compose` so the two widgets render sizes identically.
    def self.human_size(n : Int32) : String
      if n < 1000
        n.to_s
      elsif n < 1_000_000
        "%.1fK" % (n / 1000.0)
      else
        "%.1fM" % (n / 1_000_000.0)
      end
    end

    # Truncates *str* to *len* characters, adding a `~` when cut. Mutt's and
    # Pine's `MessageIndex` share this deliberately (same truncation rule). The
    # generic implementation lives in the crystallabs-helpers shard.
    def self.truncate(str : String, len : Int32) : String
      Crystallabs::Helpers::Format.truncate str, len, '~'
    end

    # Left-justifies *text* to *cols* terminal columns by appending spaces:
    # `String#ljust` measured in display width (`Unicode.str_width` under
    # *full_unicode*) rather than codepoints, so wide (CJK, emoji) text keeps
    # its column. *measure* is the text whose width counts, for a *text*
    # carrying markup the terminal never shows — pass the original of a
    # brace-escaped string.
    def self.ljust(text : String, cols : Int32, full_unicode : Bool, measure : String = text) : String
      pad = cols - Unicode.str_width(measure, full_unicode)
      pad > 0 ? text + " " * pad : text
    end

    # Escapes literal braces so untrusted text can't inject `{}` content tags
    # (`{` → `{open}`, `}` → `{close}` — single pass, so the braces of an
    # inserted `{open}` are never themselves re-escaped). The canonical
    # implementation behind `Widget.escape_tags`, homed here so model-layer
    # code (e.g. `Chat::Diff`) can escape without depending on the widget
    # layer.
    def self.escape_braces(text : String) : String
      return text unless text.includes?('{') || text.includes?('}')
      text.gsub(/[{}]/) { |m| m == "{" ? "{open}" : "{close}" }
    end
  end
end
