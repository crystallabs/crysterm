module Crysterm
  module Mixin
    module Uid
      @@uid : Atomic(Int32) = Atomic.new 0i32

      # Returns next widget UID.
      #
      # UIDs are generated sequentially, with ID sequence kept in an int32.
      def self.next_uid : Int32
        @@uid.add 1
      end

      # Unique ID. Auto-incremented. The setter is internal (`protected`) — the
      # value is assigned once at construction and the CSS cascade keys off it.
      getter uid : Int32 = ::Crysterm::Mixin::Uid.next_uid

      # The uid in `String` form, memoized: the CSS cascade keys nodes by this
      # string on each recompute, so caching avoids a per-widget `Int#to_s`.
      @uid_s : String?

      # :ditto:
      def uid_s : String
        @uid_s ||= @uid.to_s
      end

      protected def uid=(value : Int32) : Int32
        @uid_s = nil
        @uid = value
      end
    end
  end
end
