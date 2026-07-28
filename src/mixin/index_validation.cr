module Crysterm
  module Mixin
    # The shared validate-don't-passthrough body of the `index_of(Int)`
    # overloads (`Mixin::ItemView`, `Mixin::ActionBar`): a raw `Int` is
    # validated against the model size rather than handed back, so a negative
    # index (which `Array#[]?` would resolve from the end) or an out-of-range
    # row is rejected up front instead of removing/firing the *last* item
    # while the raw value corrupts the index bookkeeping downstream.
    module IndexValidation
      # *index* itself (as `Int32`) when within `0...size`, else `nil`.
      private def validated_index(index : Int, size : Int32) : Int32?
        i = index.to_i
        (0 <= i < size) ? i : nil
      end
    end
  end
end
