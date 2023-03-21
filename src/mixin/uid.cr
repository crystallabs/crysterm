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
      property uid : Int32 = next_uid
    end
  end
end
