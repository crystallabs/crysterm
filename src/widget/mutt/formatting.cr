module Crysterm
  class Widget
    module Mutt
      # Formats a byte count the way Mutt's `%c` does: bytes, then `K`/`M` with
      # one decimal (e.g. `842`, `1.2K`, `3.4M`). Shared by `MessageIndex` and
      # `Compose` so the two widgets render sizes identically.
      def self.human_size(n : Int32) : String
        if n < 1000
          n.to_s
        elsif n < 1_000_000
          "%.1fK" % (n / 1000.0)
        else
          "%.1fM" % (n / 1_000_000.0)
        end
      end

      # Truncates *str* to *len* characters, adding a `~` when cut. Pine's flat
      # `MessageIndex` shares this deliberately (same truncation rule). The
      # generic implementation lives in the crystallabs-helpers shard.
      def self.truncate(str : String, len : Int32) : String
        Crystallabs::Helpers::Format.truncate str, len, '~'
      end
    end
  end
end
