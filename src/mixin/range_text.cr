module Crysterm
  module Mixin
    # Expands the `%p`/`%v`/`%m`/`%M` placeholders (percent / value / maximum /
    # minimum) shared by the range/progress text templates. Values arrive
    # pre-formatted; this owns only the placeholder mapping.
    module RangeText
      protected def format_range_text(fmt : String, percent : String, value : String, maximum : String, minimum : String) : String
        # Unknown `%x`, a lone `%`, and adjacent tokens fall through unmatched.
        fmt.gsub(/%[pvmM]/) do |token|
          case token
          when "%p" then percent
          when "%v" then value
          when "%m" then maximum
          else           minimum # "%M"
          end
        end
      end
    end
  end
end
