require "yaml"

module Crysterm
  module Mixin
    module Data
      # Arbitrary extra/external content attached to widget as YAML
      property data : YAML::Any?
    end
  end
end
