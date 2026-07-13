module Crysterm
  module Mixin
    # Expands the `%p`/`%v`/`%m`/`%M` placeholders (percent / value / maximum /
    # minimum) shared by the range/progress text templates of
    # `Widget::ProgressBar` and `Widget::Gauge`. Each value is pre-formatted by
    # the caller — `ProgressBar` uses plain `to_s` on its `Int32` range, `Gauge`
    # uses `Graph::Scale.fmt` on its `Float64` range — so this owns only the
    # placeholder mapping, keeping the two templates from drifting apart when a
    # placeholder is added or renamed.
    module RangeText
      protected def format_range_text(fmt : String, percent : String, value : String, maximum : String, minimum : String) : String
        # Single pass, one allocation. Unknown `%x`, a lone `%`, and adjacent
        # tokens are handled by the regex (only `%p`/`%v`/`%m`/`%M` match).
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
