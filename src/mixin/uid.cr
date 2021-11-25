module Crysterm
  module Mixin
    module Uid
      macro included
        @@uid : Atomic(Int32) = Atomic.new 0i32
      end

      # Unique ID. Auto-incremented.
      #
      # NOTE This is an instance var; setting it to the value of `@@uid` happens in includers.
      property uid : Int32

      def next_uid : Int32
        @@uid.add 1
      end
    end
  end
end
