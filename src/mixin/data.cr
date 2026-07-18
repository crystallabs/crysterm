module Crysterm
  module Mixin
    module Data
      # Arbitrary extra/external content attached to the widget — a primitive
      # scalar (Qt's `QObject::setProperty`-ish free payload). Same union
      # `Action#data` uses; see `Crysterm::UserData`.
      property data : ::Crysterm::UserData?
    end
  end
end
