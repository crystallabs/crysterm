module Crysterm
  module Mixin
    module Uid
      macro included
        @@uid = 0
      end

      # Unique ID. Auto-incremented.
      property uid : Int32

      def next_uid
        @@uid += 1
      end
    end
  end
end
