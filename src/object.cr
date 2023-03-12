module Crysterm
  # Base class for Crysterm objects. Adds `EventHandler` mixin.
  class Object
    include EventHandler
  end
end
