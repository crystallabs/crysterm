module Crysterm
  module Mixin
    module Uid
      macro included
        @@uid = Atomic.new 0i32
      end

      # Unique ID. Auto-incremented.
      #
      # NOTE This is an instance var; setting it to the value of `@@uid` happens elsewhere.
      property uid : Atomic(Int32)

      def next_uid
        @@uid.add 1
      end
    end
  end
end
