module Crysterm
  module Mixin
    module Pos
      # NOTE See what this is for and if it can be unified/integrated into
      # something else (or if something else can be removed in favor of this)
      # to removal total amount of code.

      # Number of times object was rendered
      property renders = 0

      # Absolute left offset.
      property aleft : Int32? = nil

      # Absolute top offset.
      property atop : Int32? = nil

      # Absolute right offset.
      property aright : Int32? = nil

      # Absolute bottom offset.
      property abottom : Int32? = nil

      property? scrollable = false

      # Last rendered position
      property lpos : LPos? = nil
    end
  end
end
