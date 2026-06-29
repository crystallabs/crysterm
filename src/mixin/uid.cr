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

      # Unique ID. Auto-incremented.
      #
      # NOTE This is an instance var; setting it to the value of `@@uid` happens in includers.
      property uid : Int32 = ::Crysterm::Mixin::Uid.next_uid

      # The uid in `String` form, memoized. The CSS cascade and document index
      # key every node by this string on each recompute (`index_tree`,
      # node-patching, `data-uid` writeback), so caching it avoids a per-widget
      # `Int#to_s` heap allocation on every cascade. The uid is effectively
      # immutable (auto-assigned, never reassigned in practice), but the setter
      # below clears the cache to stay correct if one ever is.
      @uid_s : String?

      # :ditto:
      def uid_s : String
        @uid_s ||= @uid.to_s
      end

      def uid=(value : Int32) : Int32
        @uid_s = nil
        @uid = value
      end
    end
  end
end
